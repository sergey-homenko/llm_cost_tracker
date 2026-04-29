# frozen_string_literal: true

require "spec_helper"
require "active_record"
require "json"
require "tempfile"

RSpec.describe "ActiveRecord storage integration" do
  before do
    establish_database_connection!

    ActiveRecord::Schema.verbose = false
    tags_column = method(:add_tags_column)
    ActiveRecord::Schema.define do
      create_table :llm_api_calls, force: true do |t|
        t.string :provider, null: false
        t.string :model, null: false
        t.integer :input_tokens, null: false, default: 0
        t.integer :output_tokens, null: false, default: 0
        t.integer :total_tokens, null: false, default: 0
        t.integer :cache_read_input_tokens, null: false, default: 0
        t.integer :cache_write_input_tokens, null: false, default: 0
        t.integer :hidden_output_tokens, null: false, default: 0
        t.decimal :input_cost, precision: 20, scale: 8
        t.decimal :cache_read_input_cost, precision: 20, scale: 8
        t.decimal :cache_write_input_cost, precision: 20, scale: 8
        t.decimal :output_cost, precision: 20, scale: 8
        t.decimal :total_cost, precision: 20, scale: 8
        t.integer :latency_ms
        t.boolean :stream, null: false, default: false
        t.string :usage_source
        t.string :provider_response_id
        t.string :pricing_mode
        tags_column.call(t)
        t.datetime :tracked_at, null: false

        t.timestamps
      end

      create_table :llm_cost_tracker_period_totals, force: true do |t|
        t.string :period, null: false
        t.date :period_start, null: false
        t.decimal :total_cost, precision: 20, scale: 8, null: false, default: 0

        t.timestamps
      end

      add_index :llm_cost_tracker_period_totals, %i[period period_start], unique: true
    end

    LlmCostTracker::LlmApiCall.reset_column_information
    LlmCostTracker::PeriodTotal.reset_column_information
  end

  after do
    disconnect_database!
  end

  it "lazy-loads the ActiveRecord store and persists events" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 500,
      latency_ms: 250,
      user_id: 42,
      feature: "chat"
    )

    expect(LlmCostTracker::LlmApiCall.count).to eq(1)

    call = LlmCostTracker::LlmApiCall.first
    expect(call.provider).to eq("openai")
    expect(call.model).to eq("gpt-4o")
    expect(call.total_cost.to_f).to eq(0.0075)
    expect(call.latency_ms).to eq(250)
    expect(call.parsed_tags).to include("user_id" => "42", "feature" => "chat")
  end

  it "persists canonical usage and cost breakdowns when columns are present" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 900,
      output_tokens: 500,
      cache_read_input_tokens: 100,
      hidden_output_tokens: 20
    )

    call = LlmCostTracker::LlmApiCall.first
    expect(call.input_tokens).to eq(900)
    expect(call.cache_read_input_tokens).to eq(100)
    expect(call.cache_write_input_tokens).to eq(0)
    expect(call.hidden_output_tokens).to eq(20)
    expect(call.input_cost.to_f).to eq(0.00225)
    expect(call.cache_read_input_cost.to_f).to eq(0.000125)
    expect(call.cache_write_input_cost.to_f).to eq(0.0)
    expect(call.total_cost.to_f).to eq(0.007375)
  end

  it "persists pricing_mode when the column is present" do
    LlmCostTracker.configure do |config|
      config.pricing_overrides = {
        "batchable-model" => {
          input: 1.0,
          output: 2.0,
          batch_input: 0.5,
          batch_output: 1.0
        }
      }
    end

    LlmCostTracker.track(
      provider: :custom,
      model: "batchable-model",
      input_tokens: 1_000_000,
      output_tokens: 1_000_000,
      pricing_mode: :batch
    )

    call = LlmCostTracker::LlmApiCall.first
    expect(call.pricing_mode).to eq("batch")
    expect(call.total_cost.to_f).to eq(1.5)
  end

  it "refreshes optional column capability checks after reset_column_information" do
    expect(LlmCostTracker::LlmApiCall.pricing_mode_column?).to be true

    ActiveRecord::Base.connection.remove_column(:llm_api_calls, :pricing_mode)
    LlmCostTracker::LlmApiCall.reset_column_information

    expect(LlmCostTracker::LlmApiCall.pricing_mode_column?).to be false
  end

  it "keeps persisted historical costs when the price file changes for later requests" do
    Tempfile.create(["llm-prices-old", ".json"]) do |old_file|
      Tempfile.create(["llm-prices-new", ".json"]) do |new_file|
        old_file.write(JSON.generate(
                         "models" => {
                           "snapshot-model" => { "input" => 1.0, "output" => 2.0 }
                         }
                       ))
        old_file.close

        new_file.write(JSON.generate(
                         "models" => {
                           "snapshot-model" => { "input" => 3.0, "output" => 4.0 }
                         }
                       ))
        new_file.close

        LlmCostTracker.configure do |config|
          config.prices_file = old_file.path
        end

        LlmCostTracker.track(
          provider: :openai,
          model: "snapshot-model",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000
        )

        LlmCostTracker.reset_configuration!
        LlmCostTracker.configure do |config|
          config.prices_file = new_file.path
        end

        LlmCostTracker.track(
          provider: :openai,
          model: "snapshot-model",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000
        )

        calls = LlmCostTracker::LlmApiCall.order(:id).to_a

        expect(calls.size).to eq(2)
        expect(calls.first.input_cost.to_f).to eq(1.0)
        expect(calls.first.output_cost.to_f).to eq(2.0)
        expect(calls.first.total_cost.to_f).to eq(3.0)
        expect(calls.second.input_cost.to_f).to eq(3.0)
        expect(calls.second.output_cost.to_f).to eq(4.0)
        expect(calls.second.total_cost.to_f).to eq(7.0)
        expect(LlmCostTracker::LlmApiCall.sum(:total_cost).to_f).to eq(10.0)
      end
    end
  end

  it "keeps monthly budget rollups in sync" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o-mini",
      input_tokens: 1_000,
      output_tokens: 0
    )

    month_total = LlmCostTracker::PeriodTotal.find_by!(period: "month", period_start: Date.current.beginning_of_month)

    expect(LlmCostTracker::PeriodTotal.where(period: "month").count).to eq(1)
    expect(month_total.total_cost.to_f).to eq(0.00265)
    expect(LlmCostTracker::LedgerStore.monthly_total).to eq(0.00265)
  end

  it "updates daily and monthly period rollups in one bulk write" do
    allow(Time).to receive(:now).and_return(Time.utc(2026, 4, 18, 12))
    received_rows = nil

    allow(LlmCostTracker::PeriodTotal).to receive(:upsert_all).and_wrap_original do |method, rows, **options|
      received_rows = rows
      method.call(rows, **options)
    end

    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    expect(LlmCostTracker::PeriodTotal).to have_received(:upsert_all).once
    expect(received_rows.map { |row| row[:period] }).to contain_exactly("month", "day")
  end

  it "qualifies PostgreSQL rollup upsert totals" do
    connection = double(adapter_name: "PostgreSQL")
    allow(connection).to receive(:quote_column_name) { |name| %("#{name}") }
    model = double(
      connection: connection,
      quoted_table_name: %("llm_cost_tracker_period_totals")
    )

    sql = LlmCostTracker::RollupUpsertSql.call(model).to_s

    expect(sql).to include(%("total_cost" = "llm_cost_tracker_period_totals"."total_cost" + excluded."total_cost"))
    expect(sql).to include(%("updated_at" = excluded."updated_at"))
  end

  it "treats MySQL-family adapters consistently for rollup upserts" do
    %w[Mysql2 Trilogy MariaDB].each do |adapter_name|
      connection = double(adapter_name: adapter_name)
      model = double(
        connection: connection,
        table_name: "llm_cost_tracker_period_totals"
      )

      sql = LlmCostTracker::RollupUpsertSql.call(model).to_s

      expect(sql).to include("VALUES(total_cost)")
      expect(sql).not_to include("excluded")
    end
  end

  it "keeps daily budget rollups in sync" do
    allow(Time).to receive(:now).and_return(Time.utc(2026, 4, 18, 12))

    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o-mini",
      input_tokens: 1_000,
      output_tokens: 0
    )

    day_total = LlmCostTracker::PeriodTotal.find_by!(period: "day", period_start: Date.new(2026, 4, 18))

    expect(LlmCostTracker::PeriodTotal.where(period: "day").count).to eq(1)
    expect(day_total.total_cost.to_f).to eq(0.00265)
    expect(LlmCostTracker::LedgerStore.daily_total(time: Time.utc(2026, 4, 18, 23))).to eq(0.00265)
  end

  it "falls back to llm_api_calls sums when period rollups are unavailable" do
    ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_period_totals)
    allow(Time).to receive(:now).and_return(Time.utc(2026, 4, 18, 12))

    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    expect(LlmCostTracker::LedgerStore.monthly_total).to eq(0.0025)
    expect(LlmCostTracker::LedgerStore.daily_total(time: Time.utc(2026, 4, 18, 23))).to eq(0.0025)
  end

  it "reads daily and monthly period totals together" do
    allow(Time).to receive(:now).and_return(Time.utc(2026, 4, 18, 12))

    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    totals = LlmCostTracker::LedgerStore.period_totals(
      %i[daily monthly],
      time: Time.utc(2026, 4, 18, 23)
    )

    expect(totals).to eq(daily: 0.0025, monthly: 0.0025)
  end

  it "does not treat latency as a tag" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      latency_ms: 123
    )

    expect(LlmCostTracker::LlmApiCall.first.parsed_tags).not_to have_key("latency_ms")
  end

  it "persists provider_response_id without treating it as a tag" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      provider_response_id: "chatcmpl_123"
    )

    call = LlmCostTracker::LlmApiCall.first

    expect(call.provider_response_id).to eq("chatcmpl_123")
    expect(call.parsed_tags).not_to have_key("provider_response_id")
  end

  it "finds stringified numeric tags through by_tag" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      user_id: 42
    )

    expect(LlmCostTracker::LlmApiCall.by_tag("user_id", "42").count).to eq(1)
  end

  it "filters by multiple tags through by_tags" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      user_id: 42,
      feature: "chat"
    )
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      user_id: 42,
      feature: "summarizer"
    )

    matching_calls = LlmCostTracker::LlmApiCall.by_tags(user_id: 42, feature: "chat")

    expect(matching_calls.count).to eq(1)
    expect(matching_calls.first.parsed_tags["feature"]).to eq("chat")
  end

  it "aggregates cost by any tag key" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "chat"
    )
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o-mini",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "summarizer"
    )
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o-mini",
      input_tokens: 1_000,
      output_tokens: 0
    )

    expect(LlmCostTracker::LlmApiCall.this_month.cost_by_tag("feature")).to eq(
      "chat" => 0.0025,
      "summarizer" => 0.00015,
      "(untagged)" => 0.00015
    )
  end

  it "groups by tag keys on the SQL side" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "chat"
    )
    LlmCostTracker.track(
      provider: :anthropic,
      model: "claude-haiku-4-5",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "summarizer"
    )

    tag_sql = LlmCostTracker::LlmApiCall.group_by_tag("feature").to_sql
    if LlmCostTracker::ActiveRecordAdapter.postgresql?(LlmCostTracker::LlmApiCall.connection)
      expect(tag_sql).to include("->>")
    else
      expect(tag_sql).to include("JSON_EXTRACT")
    end
    expect(LlmCostTracker::LlmApiCall.group_by_tag("feature").sum(:total_cost).transform_values(&:to_f)).to eq(
      "chat" => 0.0025,
      "summarizer" => 0.001
    )
  end

  it "groups costs by day on the SQL side" do
    LlmCostTracker::LlmApiCall.create!(
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 1.25,
      tags: tags_for_database({}),
      tracked_at: Time.utc(2026, 4, 18, 10, 30)
    )
    LlmCostTracker::LlmApiCall.create!(
      provider: "openai",
      model: "gpt-4o-mini",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 2.75,
      tags: tags_for_database({}),
      tracked_at: Time.utc(2026, 4, 18, 23, 59)
    )
    LlmCostTracker::LlmApiCall.create!(
      provider: "anthropic",
      model: "claude-haiku-4-5",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 3.5,
      tags: tags_for_database({}),
      tracked_at: Time.utc(2026, 4, 19, 0, 1)
    )

    period_sql = LlmCostTracker::LlmApiCall.group_by_period(:day).to_sql
    if LlmCostTracker::ActiveRecordAdapter.postgresql?(LlmCostTracker::LlmApiCall.connection)
      expect(period_sql).to include("DATE_TRUNC")
    else
      expect(period_sql).to include("DATE_FORMAT")
    end
    expect(LlmCostTracker::LlmApiCall.group_by_period(:day).sum(:total_cost).transform_values(&:to_f)).to eq(
      "2026-04-18" => 4.0,
      "2026-04-19" => 3.5
    )
  end

  it "groups costs by month on the SQL side" do
    LlmCostTracker::LlmApiCall.create!(
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 1.25,
      tags: tags_for_database({}),
      tracked_at: Time.utc(2026, 4, 18)
    )
    LlmCostTracker::LlmApiCall.create!(
      provider: "anthropic",
      model: "claude-haiku-4-5",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 3.5,
      tags: tags_for_database({}),
      tracked_at: Time.utc(2026, 5, 1)
    )

    expect(LlmCostTracker::LlmApiCall.group_by_period(:month).sum(:total_cost).transform_values(&:to_f)).to eq(
      "2026-04" => 1.25,
      "2026-05" => 3.5
    )
  end

  it "groups by a whitelisted custom timestamp column" do
    LlmCostTracker::LlmApiCall.create!(
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 1.25,
      tags: tags_for_database({}),
      tracked_at: Time.utc(2026, 4, 18),
      created_at: Time.utc(2026, 5, 2),
      updated_at: Time.utc(2026, 5, 2)
    )

    expect(
      LlmCostTracker::LlmApiCall.group_by_period(:day, column: :created_at).sum(:total_cost).transform_values(&:to_f)
    ).to eq("2026-05-02" => 1.25)
  end

  it "builds PostgreSQL period grouping SQL" do
    allow(LlmCostTracker::LlmApiCall.connection).to receive(:adapter_name).and_return("PostgreSQL")

    day_sql = LlmCostTracker::LlmApiCall.group_by_period(:day).to_sql
    month_sql = LlmCostTracker::LlmApiCall.group_by_period(:month).to_sql

    expect(day_sql).to include("TO_CHAR(DATE_TRUNC('day'")
    expect(day_sql).to include("'YYYY-MM-DD'")
    expect(month_sql).to include("TO_CHAR(DATE_TRUNC('month'")
    expect(month_sql).to include("'YYYY-MM'")
  end

  it "builds MySQL-family period grouping SQL" do
    %w[Mysql2 Trilogy MariaDB].each do |adapter_name|
      connection = LlmCostTracker::LlmApiCall.connection
      allow(connection).to receive(:adapter_name).and_return(adapter_name)
      allow(LlmCostTracker::ActiveRecordAdapter).to receive(:postgresql?).with(connection).and_return(false)
      allow(LlmCostTracker::ActiveRecordAdapter).to receive(:mysql?).with(connection).and_return(true)

      day_sql = LlmCostTracker::LlmApiCall.group_by_period(:day).to_sql
      month_sql = LlmCostTracker::LlmApiCall.group_by_period(:month).to_sql

      expect(day_sql).to include("DATE_FORMAT")
      expect(day_sql).to include("'%Y-%m-%d'")
      expect(month_sql).to include("DATE_FORMAT")
      expect(month_sql).to include("'%Y-%m'")
    end
  end

  it "composes period grouping with other scopes" do
    tracked_at = Time.now.utc

    LlmCostTracker::LlmApiCall.create!(
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 1.25,
      tags: tags_for_database({}),
      tracked_at: tracked_at
    )
    LlmCostTracker::LlmApiCall.create!(
      provider: "anthropic",
      model: "claude-haiku-4-5",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 3.5,
      tags: tags_for_database({}),
      tracked_at: tracked_at
    )

    result = LlmCostTracker::LlmApiCall.this_month.where(provider: "openai").group_by_period(:day).sum(:total_cost)

    expect(result.transform_values(&:to_f)).to eq(tracked_at.strftime("%Y-%m-%d") => 1.25)
  end

  it "rejects invalid periods before building SQL" do
    expect do
      LlmCostTracker::LlmApiCall.group_by_period("day; DROP TABLE llm_api_calls")
    end.to raise_error(ArgumentError, /invalid period/)
  end

  it "rejects invalid period columns before building SQL" do
    expect do
      LlmCostTracker::LlmApiCall.group_by_period(:day, column: "tracked_at; DROP TABLE llm_api_calls")
    end.to raise_error(ArgumentError, /invalid period column/)
  end

  it "supports safe tag keys with dots and dashes" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0,
      "feature.name" => "chat"
    )
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o-mini",
      input_tokens: 1_000,
      output_tokens: 0,
      "feature.name" => "summarizer"
    )

    expect(LlmCostTracker::LlmApiCall.cost_by_tag("feature.name")).to eq(
      "chat" => 0.0025,
      "summarizer" => 0.00015
    )
  end

  it "composes tag grouping with other scopes" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "chat"
    )
    LlmCostTracker.track(
      provider: :anthropic,
      model: "claude-haiku-4-5",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "chat"
    )

    result = LlmCostTracker::LlmApiCall.this_month.where(provider: "openai").group_by_tag("feature").sum(:total_cost)

    expect(result.transform_values(&:to_f)).to eq("chat" => 0.0025)
  end

  it "rejects invalid tag keys before building SQL" do
    expect do
      LlmCostTracker::LlmApiCall.group_by_tag("feature; DROP TABLE llm_api_calls")
    end.to raise_error(ArgumentError, /invalid tag key/)
  end

  it "filters by tag convenience scopes" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      user_id: 42,
      feature: "chat"
    )

    expect(LlmCostTracker::LlmApiCall.by_tag("user_id", 42).count).to eq(1)
    expect(LlmCostTracker::LlmApiCall.by_tag("feature", "chat").count).to eq(1)
    expect(LlmCostTracker::LlmApiCall.by_tag("feature", "summarizer").count).to eq(0)
  end

  it "escapes text tag queries so wildcard values do not over-match" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      feature: "100%"
    )
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      feature: "1000"
    )

    expect(LlmCostTracker::LlmApiCall.by_tag("feature", "100%").count).to eq(1)
  end

  it "filters calls with and without known pricing" do
    LlmCostTracker.configure do |config|
      config.unknown_pricing_behavior = :ignore
    end

    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5
    )
    LlmCostTracker.track(
      provider: :openai,
      model: "unknown-chat-model",
      input_tokens: 10,
      output_tokens: 5
    )

    expect(LlmCostTracker::LlmApiCall.with_cost.count).to eq(1)
    expect(LlmCostTracker::LlmApiCall.without_cost.count).to eq(1)
    expect(LlmCostTracker::LlmApiCall.unknown_pricing.first.model).to eq("unknown-chat-model")
  end

  it "aggregates latency by model and provider" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      latency_ms: 100
    )
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      latency_ms: 300
    )

    expect(LlmCostTracker::LlmApiCall.with_latency.count).to eq(2)
    expect(LlmCostTracker::LlmApiCall.average_latency_ms).to eq(200.0)
    expect(LlmCostTracker::LlmApiCall.latency_by_model).to eq("gpt-4o" => 200.0)
    expect(LlmCostTracker::LlmApiCall.latency_by_provider).to eq("openai" => 200.0)
  end

  it "does not write latency when an older schema has no latency column" do
    ActiveRecord::Base.connection.remove_column(:llm_api_calls, :latency_ms)
    LlmCostTracker::LlmApiCall.reset_column_information

    expect do
      LlmCostTracker.track(
        provider: :openai,
        model: "gpt-4o",
        input_tokens: 10,
        output_tokens: 5,
        latency_ms: 123
      )
    end.not_to raise_error
    expect(LlmCostTracker::LlmApiCall.first.attributes).not_to have_key("latency_ms")
  end

  it "raises when ActiveRecord storage fails" do
    require "llm_cost_tracker/ledger_store"

    allow(LlmCostTracker::LedgerStore).to receive(:save)
      .and_raise(ActiveRecord::StatementInvalid, "database down")

    expect do
      LlmCostTracker.track(
        provider: :openai,
        model: "gpt-4o",
        input_tokens: 10,
        output_tokens: 5
      )
    end.to raise_error(ActiveRecord::StatementInvalid, /database down/)
  end

  it "returns daily cost keys as strings across adapters" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5
    )

    expect(LlmCostTracker::LlmApiCall.daily_costs.keys).to all(be_a(String))
  end

  it "detects PostgreSQL JSONB tag columns" do
    expect(LlmCostTracker::LlmApiCall.tags_json_column?).to be true
    expect(LlmCostTracker::LlmApiCall.tags_jsonb_column?).to be true
  end

  it "detects Trilogy JSON tag columns as MySQL JSON" do
    column = double(type: :json, sql_type: "json")

    %w[Mysql2 Trilogy MariaDB].each do |adapter_name|
      capabilities = LlmCostTracker::LlmApiCall.send(:build_lct_schema_capabilities, { "tags" => column }, adapter_name)

      expect(capabilities.fetch(:tags_mysql_json)).to be true
    end
  end

  it "builds a JSONB containment query for PostgreSQL JSONB tag columns" do
    allow(LlmCostTracker::LlmApiCall).to receive_messages(tags_json_column?: true, tags_jsonb_column?: true,
                                                          tags_mysql_json_column?: false)

    sql = LlmCostTracker::LlmApiCall.by_tags(user_id: 42, feature: "chat").to_sql

    expect(sql).to include("tags @>")
    expect(sql).to include('{"user_id":"42","feature":"chat"}')
  end

  it "builds a JSON_CONTAINS query for MySQL JSON tag columns" do
    allow(LlmCostTracker::LlmApiCall).to receive_messages(tags_json_column?: true, tags_jsonb_column?: false,
                                                          tags_mysql_json_column?: true)

    sql = LlmCostTracker::LlmApiCall.by_tags(user_id: 42, feature: "chat").to_sql

    expect(sql).to include("JSON_CONTAINS(tags,")
    expect(sql).to include('{"user_id":"42","feature":"chat"}')
  end

  it "builds MySQL-family tag value SQL" do
    %w[Mysql2 Trilogy MariaDB].each do |adapter_name|
      connection = LlmCostTracker::LlmApiCall.connection
      allow(connection).to receive(:adapter_name).and_return(adapter_name)
      allow(LlmCostTracker::ActiveRecordAdapter).to receive(:postgresql?).with(connection).and_return(false)
      allow(LlmCostTracker::ActiveRecordAdapter).to receive(:mysql?).with(connection).and_return(true)
      allow(LlmCostTracker::LlmApiCall).to receive(:tags_jsonb_column?).and_return(false)

      sql = LlmCostTracker::LlmApiCall.tag_value_expression("user_id")

      expect(sql).to include("JSON_UNQUOTE(JSON_EXTRACT")
      expect(sql).to include(%('$."user_id"'))
    end
  end

  it "does not double-count the latest event in budget callbacks" do
    budget_data = nil

    LlmCostTracker.configure do |config|
      config.monthly_budget = 0.001
      config.on_budget_exceeded = ->(data) { budget_data = data }
    end

    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    expect(LlmCostTracker::LlmApiCall.total_cost).to eq(0.0025)
    expect(budget_data[:monthly_total]).to eq(0.0025)
  end

  it "notifies once when :notify first crosses the monthly budget" do
    budget_totals = []

    LlmCostTracker.configure do |config|
      config.monthly_budget = 0.004
      config.on_budget_exceeded = ->(data) { budget_totals << data[:monthly_total] }
    end

    3.times do
      LlmCostTracker.track(
        provider: :openai,
        model: "gpt-4o",
        input_tokens: 1_000,
        output_tokens: 0
      )
    end

    expect(budget_totals).to eq([0.005])
  end

  it "notifies once when :notify first crosses the daily budget" do
    budget_totals = []

    LlmCostTracker.configure do |config|
      config.daily_budget = 0.004
      config.on_budget_exceeded = ->(data) { budget_totals << data[:daily_total] }
    end

    3.times do
      LlmCostTracker.track(
        provider: :openai,
        model: "gpt-4o",
        input_tokens: 1_000,
        output_tokens: 0
      )
    end

    expect(budget_totals).to eq([0.005])
  end

  it "blocks before a request when the ActiveRecord monthly budget is exhausted" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    LlmCostTracker.configure do |config|
      config.monthly_budget = 0.001
      config.budget_exceeded_behavior = :block_requests
    end

    expect do
      LlmCostTracker::Tracker.enforce_budget!
    end.to raise_error(LlmCostTracker::BudgetExceededError) { |error|
      expect(error.monthly_total).to eq(0.0025)
      expect(error.budget).to eq(0.001)
    }
  end

  it "blocks before a request when the ActiveRecord daily budget is exhausted" do
    LlmCostTracker.track(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    LlmCostTracker.configure do |config|
      config.daily_budget = 0.001
      config.budget_exceeded_behavior = :block_requests
    end

    expect do
      LlmCostTracker::Tracker.enforce_budget!
    end.to raise_error(LlmCostTracker::BudgetExceededError) { |error|
      expect(error.budget_type).to eq(:daily)
      expect(error.daily_total).to eq(0.0025)
      expect(error.budget).to eq(0.001)
    }
  end

  it "calculates daily totals for the requested day" do
    allow(Time).to receive(:now).and_return(Time.utc(2026, 4, 18, 12))
    LlmCostTracker.track(provider: :openai, model: "gpt-4o", input_tokens: 1_000, output_tokens: 0)

    allow(Time).to receive(:now).and_return(Time.utc(2026, 4, 17, 12))
    LlmCostTracker.track(provider: :openai, model: "gpt-4o", input_tokens: 1_000, output_tokens: 0)

    total = LlmCostTracker::LedgerStore.daily_total(time: Time.utc(2026, 4, 18, 23))

    expect(total).to eq(0.0025)
  end
end
