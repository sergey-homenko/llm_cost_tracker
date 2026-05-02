# frozen_string_literal: true

require "spec_helper"
require "active_record"
require "json"
require "tempfile"

RSpec.describe "ActiveRecord storage integration" do
  before do
    establish_database_connection!

    create_lct_tables!

    LlmCostTracker::Ledger::Call.reset_column_information
    LlmCostTracker::Ledger::ServiceCharge.reset_column_information
    LlmCostTracker::Ledger::Period::Total.reset_column_information
    LlmCostTracker::Ingestion::Event.reset_column_information
    LlmCostTracker::Ingestion::Lease.reset_column_information
    allow(LlmCostTracker::Ingestion::Worker).to receive(:ensure_started)
  end

  after do
    disconnect_database!
  end

  def track_and_flush(**kwargs)
    event = LlmCostTracker.track(**kwargs)
    LlmCostTracker.flush!
    event
  end

  def build_event(event_id:, total_cost: 0.0025, tracked_at: Time.now.utc, tags: {})
    LlmCostTracker::Event.new(
      event_id: event_id,
      provider: "openai",
      model: "gpt-4o",
      token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1_000, output_tokens: 0),
      pricing_mode: nil,
      cost: {
        input_cost: total_cost,
        cache_read_input_cost: 0,
        cache_write_input_cost: 0,
        cache_write_1h_input_cost: 0,
        output_cost: 0,
        total_cost: total_cost
      },
      tags: tags,
      latency_ms: nil,
      stream: false,
      usage_source: "manual",
      provider_response_id: nil,
      tracked_at: tracked_at,
      cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE,
      pricing_snapshot: nil,
      service_charges: []
    )
  end

  it "lazy-loads the ActiveRecord store and persists events" do
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 500,
      latency_ms: 250,
      user_id: 42,
      feature: "chat"
    )

    expect(LlmCostTracker::Ledger::Call.count).to eq(1)

    call = LlmCostTracker::Ledger::Call.first
    expect(call.provider).to eq("openai")
    expect(call.model).to eq("gpt-4o")
    expect(call.total_cost.to_f).to eq(0.0075)
    expect(call.latency_ms).to eq(250)
    expect(call.parsed_tags).to include("user_id" => "42", "feature" => "chat")
  end

  it "persists canonical usage and cost breakdowns" do
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 900,
      output_tokens: 500,
      cache_read_input_tokens: 100,
      hidden_output_tokens: 20
    )

    call = LlmCostTracker::Ledger::Call.first
    expect(call.input_tokens).to eq(900)
    expect(call.cache_read_input_tokens).to eq(100)
    expect(call.cache_write_input_tokens).to eq(0)
    expect(call.hidden_output_tokens).to eq(20)
    expect(call.input_cost.to_f).to eq(0.00225)
    expect(call.cache_read_input_cost.to_f).to eq(0.000125)
    expect(call.cache_write_input_cost.to_f).to eq(0.0)
    expect(call.cache_write_1h_input_cost.to_f).to eq(0.0)
    expect(call.total_cost.to_f).to eq(0.007375)
    expect(call.cost_status).to eq(LlmCostTracker::Billing::CostStatus::COMPLETE)
    expect(call.pricing_snapshot.fetch("rates").keys).to include("input", "cache_read_input", "output")
  end

  it "stores service charges atomically with the parent call" do
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0,
      service_charges: [
        {
          component: :web_search_request,
          quantity: 1,
          rate_amount: 10,
          rate_quantity: 1_000,
          cost: 0.01,
          pricing_basis: LlmCostTracker::Billing::ServiceCharge::PROVIDER_USAGE_BASIS
        }
      ]
    )

    call = LlmCostTracker::Ledger::Call.first
    charge = LlmCostTracker::Ledger::ServiceCharge.first

    expect(call.total_cost.to_f).to eq(0.0125)
    expect(call.cost_status).to eq(LlmCostTracker::Billing::CostStatus::COMPLETE)
    expect(charge.llm_api_call_id).to eq(call.id)
    expect(charge.component).to eq("web_search_request")
    expect(charge.cost.to_f).to eq(0.01)
  end

  it "marks calls with unknown service charges as partial when token pricing is known" do
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0,
      service_charges: [
        {
          component: :grounding_request,
          quantity: 1,
          cost_status: LlmCostTracker::Billing::CostStatus::UNKNOWN
        }
      ]
    )

    call = LlmCostTracker::Ledger::Call.first

    expect(call.total_cost.to_f).to eq(0.0025)
    expect(call.cost_status).to eq(LlmCostTracker::Billing::CostStatus::PARTIAL)
  end

  it "persists pricing_mode" do
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

    track_and_flush(
      provider: :custom,
      model: "batchable-model",
      input_tokens: 1_000_000,
      output_tokens: 1_000_000,
      pricing_mode: :batch
    )

    call = LlmCostTracker::Ledger::Call.first
    expect(call.pricing_mode).to eq("batch")
    expect(call.total_cost.to_f).to eq(1.5)
  end

  it "refreshes current schema checks after reset_column_information" do
    expect(LlmCostTracker::Ledger::Schema::Calls.current_schema?).to be true

    ActiveRecord::Base.connection.remove_column(:llm_api_calls, :pricing_mode)
    LlmCostTracker::Ledger::Call.reset_column_information

    expect(LlmCostTracker::Ledger::Schema::Calls.current_schema?).to be false
    expect(LlmCostTracker::Ledger::Schema::Calls.missing_current_schema_columns).to include("pricing_mode")
    expect(LlmCostTracker::Ledger::Schema::Calls.current_schema_errors.join).to include("missing columns: pricing_mode")
  end

  it "reports adapter-specific tag column type errors" do
    [
      ["PostgreSQL", double(type: :json, sql_type: "json"), "tags column must use jsonb"],
      ["Mysql2", double(type: :text, sql_type: "text"), "tags column must use json"]
    ].each do |adapter_name, column, message|
      capabilities = LlmCostTracker::Ledger::Schema::Calls.send(
        :build_schema_capabilities,
        { "tags" => column },
        adapter_name
      )

      expect(capabilities.fetch(:current_schema_errors)).to include(message)
    end
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

        track_and_flush(
          provider: :openai,
          model: "snapshot-model",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000
        )

        LlmCostTracker.reset_configuration!
        LlmCostTracker.configure do |config|
          config.prices_file = new_file.path
        end

        track_and_flush(
          provider: :openai,
          model: "snapshot-model",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000
        )

        calls = LlmCostTracker::Ledger::Call.order(:id).to_a

        expect(calls.size).to eq(2)
        expect(calls.first.input_cost.to_f).to eq(1.0)
        expect(calls.first.output_cost.to_f).to eq(2.0)
        expect(calls.first.total_cost.to_f).to eq(3.0)
        expect(calls.second.input_cost.to_f).to eq(3.0)
        expect(calls.second.output_cost.to_f).to eq(4.0)
        expect(calls.second.total_cost.to_f).to eq(7.0)
        expect(LlmCostTracker::Ledger::Call.sum(:total_cost).to_f).to eq(10.0)
      end
    end
  end

  it "keeps monthly budget rollups in sync" do
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )
    track_and_flush(
      provider: :openai,
      model: "gpt-4o-mini",
      input_tokens: 1_000,
      output_tokens: 0
    )

    month_total = LlmCostTracker::Ledger::Period::Total.find_by!(
      period: "month",
      period_start: Date.current.beginning_of_month
    )

    expect(LlmCostTracker::Ledger::Period::Total.where(period: "month").count).to eq(1)
    expect(month_total.total_cost.to_f).to eq(0.00265)
    total = LlmCostTracker::Ledger::Period::Totals.call(%i[monthly], time: Time.now.utc).fetch(:monthly)
    expect(total).to eq(0.00265)
  end

  it "updates daily and monthly period rollups in one bulk write" do
    allow(Time).to receive(:now).and_return(Time.utc(2026, 4, 18, 12))
    received_rows = nil

    allow(LlmCostTracker::Ledger::Period::Total).to receive(:upsert_all).and_wrap_original do |method, rows, **options|
      received_rows = rows
      method.call(rows, **options)
    end

    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    expect(LlmCostTracker::Ledger::Period::Total).to have_received(:upsert_all).once
    expect(received_rows.map { |row| row[:period] }).to contain_exactly("month", "day")
  end

  it "skips duplicate event ids within one insert batch before incrementing rollups" do
    event = build_event(event_id: "duplicate-event")

    LlmCostTracker::Ledger::Store.insert_many([event, event])

    expect(LlmCostTracker::Ledger::Call.where(event_id: "duplicate-event").count).to eq(1)
    expect(LlmCostTracker::Ledger::Period::Totals.call(%i[daily monthly], time: event.tracked_at)).to eq(
      daily: 0.0025,
      monthly: 0.0025
    )
  end

  it "stringifies nested tag keys and values before storing" do
    event = build_event(event_id: "nested-tags", tags: { metadata: { user_id: 42, active: true } })

    LlmCostTracker::Ledger::Store.insert_many([event])

    expect(LlmCostTracker::Ledger::Call.first.parsed_tags).to eq(
      "metadata" => { "user_id" => "42", "active" => "true" }
    )
  end

  it "qualifies PostgreSQL rollup upsert totals" do
    connection = double(adapter_name: "PostgreSQL")
    allow(connection).to receive(:quote_column_name) { |name| %("#{name}") }
    allow(LlmCostTracker::Ledger::Period::Total).to receive(:connection).and_return(connection)
    allow(LlmCostTracker::Ledger::Period::Total)
      .to receive(:quoted_table_name)
      .and_return(%("llm_cost_tracker_period_totals"))

    sql = LlmCostTracker::Ledger::Rollups::UpsertSql.call.to_s

    expect(sql).to include(%("total_cost" = "llm_cost_tracker_period_totals"."total_cost" + excluded."total_cost"))
    expect(sql).to include(%("updated_at" = excluded."updated_at"))
  end

  it "treats MySQL-family adapters consistently for rollup upserts" do
    %w[Mysql2 Trilogy MariaDB].each do |adapter_name|
      connection = double(adapter_name: adapter_name)
      allow(LlmCostTracker::Ledger::Period::Total).to receive(:connection).and_return(connection)

      sql = LlmCostTracker::Ledger::Rollups::UpsertSql.call.to_s

      expect(sql).to include("VALUES(total_cost)")
      expect(sql).not_to include("excluded")
    end
  end

  it "keeps daily budget rollups in sync" do
    allow(Time).to receive(:now).and_return(Time.utc(2026, 4, 18, 12))

    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )
    track_and_flush(
      provider: :openai,
      model: "gpt-4o-mini",
      input_tokens: 1_000,
      output_tokens: 0
    )

    day_total = LlmCostTracker::Ledger::Period::Total.find_by!(period: "day", period_start: Date.new(2026, 4, 18))

    expect(LlmCostTracker::Ledger::Period::Total.where(period: "day").count).to eq(1)
    expect(day_total.total_cost.to_f).to eq(0.00265)
    total = LlmCostTracker::Ledger::Period::Totals
            .call(%i[daily], time: Time.utc(2026, 4, 18, 23))
            .fetch(:daily)
    expect(total).to eq(0.00265)
  end

  it "raises when period rollups are unavailable" do
    ActiveRecord::Base.connection.drop_table(:llm_cost_tracker_period_totals)
    allow(Time).to receive(:now).and_return(Time.utc(2026, 4, 18, 12))

    expect do
      track_and_flush(
        provider: :openai,
        model: "gpt-4o",
        input_tokens: 1_000,
        output_tokens: 0
      )
    end.to raise_error(LlmCostTracker::Error, /llm_cost_tracker_period_totals/)
  end

  it "reads daily and monthly period totals together" do
    allow(Time).to receive(:now).and_return(Time.utc(2026, 4, 18, 12))

    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    totals = LlmCostTracker::Ledger::Period::Totals.call(
      %i[daily monthly],
      time: Time.utc(2026, 4, 18, 23)
    )

    expect(totals).to eq(daily: 0.0025, monthly: 0.0025)
  end

  it "does not treat latency as a tag" do
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      latency_ms: 123
    )

    expect(LlmCostTracker::Ledger::Call.first.parsed_tags).not_to have_key("latency_ms")
  end

  it "persists provider_response_id without treating it as a tag" do
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      provider_response_id: "chatcmpl_123"
    )

    call = LlmCostTracker::Ledger::Call.first

    expect(call.provider_response_id).to eq("chatcmpl_123")
    expect(call.parsed_tags).not_to have_key("provider_response_id")
  end

  it "finds stringified numeric tags through by_tag" do
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      user_id: 42
    )

    expect(LlmCostTracker::Ledger::Call.by_tag("user_id", "42").count).to eq(1)
  end

  it "filters by multiple tags through by_tags" do
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      user_id: 42,
      feature: "chat"
    )
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      user_id: 42,
      feature: "summarizer"
    )

    matching_calls = LlmCostTracker::Ledger::Call.by_tags(user_id: 42, feature: "chat")

    expect(matching_calls.count).to eq(1)
    expect(matching_calls.first.parsed_tags["feature"]).to eq("chat")
  end

  it "aggregates cost by any tag key" do
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "chat"
    )
    track_and_flush(
      provider: :openai,
      model: "gpt-4o-mini",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "summarizer"
    )
    track_and_flush(
      provider: :openai,
      model: "gpt-4o-mini",
      input_tokens: 1_000,
      output_tokens: 0
    )

    rows = LlmCostTracker::Ledger::Call.this_month.cost_by_tag("feature")

    expect(rows.map { |row| [row.name, row.total_cost.to_f] }).to eq(
      [
        ["chat", 0.0025],
        ["summarizer", 0.00015],
        ["(untagged)", 0.00015]
      ]
    )
  end

  it "groups by tag keys on the SQL side" do
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "chat"
    )
    track_and_flush(
      provider: :anthropic,
      model: "claude-haiku-4-5",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "summarizer"
    )

    tag_sql = LlmCostTracker::Ledger::Call.group_by_tag("feature").to_sql
    if LlmCostTracker::Ledger::Schema::Adapter.postgresql?(LlmCostTracker::Ledger::Call.connection)
      expect(tag_sql).to include("->>")
    else
      expect(tag_sql).to include("JSON_EXTRACT")
    end
    expect(LlmCostTracker::Ledger::Call.group_by_tag("feature").sum(:total_cost).transform_values(&:to_f)).to eq(
      "chat" => 0.0025,
      "summarizer" => 0.001
    )
  end

  it "groups costs by day on the SQL side" do
    LlmCostTracker::Ledger::Call.create!(
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 1.25,
      tags: tags_for_database({}),
      tracked_at: Time.utc(2026, 4, 18, 10, 30)
    )
    LlmCostTracker::Ledger::Call.create!(
      provider: "openai",
      model: "gpt-4o-mini",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 2.75,
      tags: tags_for_database({}),
      tracked_at: Time.utc(2026, 4, 18, 23, 59)
    )
    LlmCostTracker::Ledger::Call.create!(
      provider: "anthropic",
      model: "claude-haiku-4-5",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 3.5,
      tags: tags_for_database({}),
      tracked_at: Time.utc(2026, 4, 19, 0, 1)
    )

    period_sql = LlmCostTracker::Ledger::Call.group_by_period(:day).to_sql
    if LlmCostTracker::Ledger::Schema::Adapter.postgresql?(LlmCostTracker::Ledger::Call.connection)
      expect(period_sql).to include("DATE_TRUNC")
    else
      expect(period_sql).to include("DATE_FORMAT")
    end
    expect(LlmCostTracker::Ledger::Call.group_by_period(:day).sum(:total_cost).transform_values(&:to_f)).to eq(
      "2026-04-18" => 4.0,
      "2026-04-19" => 3.5
    )
  end

  it "groups costs by month on the SQL side" do
    LlmCostTracker::Ledger::Call.create!(
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 1.25,
      tags: tags_for_database({}),
      tracked_at: Time.utc(2026, 4, 18)
    )
    LlmCostTracker::Ledger::Call.create!(
      provider: "anthropic",
      model: "claude-haiku-4-5",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 3.5,
      tags: tags_for_database({}),
      tracked_at: Time.utc(2026, 5, 1)
    )

    expect(LlmCostTracker::Ledger::Call.group_by_period(:month).sum(:total_cost).transform_values(&:to_f)).to eq(
      "2026-04" => 1.25,
      "2026-05" => 3.5
    )
  end

  it "groups by a whitelisted custom timestamp column" do
    LlmCostTracker::Ledger::Call.create!(
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
      LlmCostTracker::Ledger::Call.group_by_period(:day, column: :created_at).sum(:total_cost).transform_values(&:to_f)
    ).to eq("2026-05-02" => 1.25)
  end

  it "builds PostgreSQL period grouping SQL" do
    allow(LlmCostTracker::Ledger::Call.connection).to receive(:adapter_name).and_return("PostgreSQL")

    day_sql = LlmCostTracker::Ledger::Call.group_by_period(:day).to_sql
    month_sql = LlmCostTracker::Ledger::Call.group_by_period(:month).to_sql

    expect(day_sql).to include("TO_CHAR(DATE_TRUNC('day'")
    expect(day_sql).to include("'YYYY-MM-DD'")
    expect(month_sql).to include("TO_CHAR(DATE_TRUNC('month'")
    expect(month_sql).to include("'YYYY-MM'")
  end

  it "builds MySQL-family period grouping SQL" do
    %w[Mysql2 Trilogy MariaDB].each do |adapter_name|
      connection = LlmCostTracker::Ledger::Call.connection
      allow(connection).to receive(:adapter_name).and_return(adapter_name)
      allow(LlmCostTracker::Ledger::Schema::Adapter).to receive(:postgresql?).with(connection).and_return(false)
      allow(LlmCostTracker::Ledger::Schema::Adapter).to receive(:mysql?).with(connection).and_return(true)

      day_sql = LlmCostTracker::Ledger::Call.group_by_period(:day).to_sql
      month_sql = LlmCostTracker::Ledger::Call.group_by_period(:month).to_sql

      expect(day_sql).to include("DATE_FORMAT")
      expect(day_sql).to include("'%Y-%m-%d'")
      expect(month_sql).to include("DATE_FORMAT")
      expect(month_sql).to include("'%Y-%m'")
    end
  end

  it "composes period grouping with other scopes" do
    tracked_at = Time.now.utc

    LlmCostTracker::Ledger::Call.create!(
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 1.25,
      tags: tags_for_database({}),
      tracked_at: tracked_at
    )
    LlmCostTracker::Ledger::Call.create!(
      provider: "anthropic",
      model: "claude-haiku-4-5",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      total_cost: 3.5,
      tags: tags_for_database({}),
      tracked_at: tracked_at
    )

    result = LlmCostTracker::Ledger::Call.this_month.where(provider: "openai").group_by_period(:day).sum(:total_cost)

    expect(result.transform_values(&:to_f)).to eq(tracked_at.strftime("%Y-%m-%d") => 1.25)
  end

  it "rejects invalid periods before building SQL" do
    expect do
      LlmCostTracker::Ledger::Call.group_by_period("day; DROP TABLE llm_api_calls")
    end.to raise_error(ArgumentError, /invalid period/)
  end

  it "rejects invalid period columns before building SQL" do
    expect do
      LlmCostTracker::Ledger::Call.group_by_period(:day, column: "tracked_at; DROP TABLE llm_api_calls")
    end.to raise_error(ArgumentError, /invalid period column/)
  end

  it "supports safe tag keys with dots and dashes" do
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0,
      "feature.name" => "chat"
    )
    track_and_flush(
      provider: :openai,
      model: "gpt-4o-mini",
      input_tokens: 1_000,
      output_tokens: 0,
      "feature.name" => "summarizer"
    )

    rows = LlmCostTracker::Ledger::Call.cost_by_tag("feature.name")

    expect(rows.map { |row| [row.name, row.total_cost.to_f] }).to eq(
      [
        ["chat", 0.0025],
        ["summarizer", 0.00015]
      ]
    )
  end

  it "composes tag grouping with other scopes" do
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "chat"
    )
    track_and_flush(
      provider: :anthropic,
      model: "claude-haiku-4-5",
      input_tokens: 1_000,
      output_tokens: 0,
      feature: "chat"
    )

    result = LlmCostTracker::Ledger::Call.this_month.where(provider: "openai").group_by_tag("feature").sum(:total_cost)

    expect(result.transform_values(&:to_f)).to eq("chat" => 0.0025)
  end

  it "rejects invalid tag keys before building SQL" do
    expect do
      LlmCostTracker::Ledger::Call.group_by_tag("feature; DROP TABLE llm_api_calls")
    end.to raise_error(ArgumentError, /invalid tag key/)
  end

  it "filters by tag convenience scopes" do
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      user_id: 42,
      feature: "chat"
    )

    expect(LlmCostTracker::Ledger::Call.by_tag("user_id", 42).count).to eq(1)
    expect(LlmCostTracker::Ledger::Call.by_tag("feature", "chat").count).to eq(1)
    expect(LlmCostTracker::Ledger::Call.by_tag("feature", "summarizer").count).to eq(0)
  end

  it "escapes text tag queries so wildcard values do not over-match" do
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      feature: "100%"
    )
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      feature: "1000"
    )

    expect(LlmCostTracker::Ledger::Call.by_tag("feature", "100%").count).to eq(1)
  end

  it "filters calls with and without known pricing" do
    LlmCostTracker.configure do |config|
      config.unknown_pricing_behavior = :ignore
    end

    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5
    )
    track_and_flush(
      provider: :openai,
      model: "unknown-chat-model",
      input_tokens: 10,
      output_tokens: 5
    )

    expect(LlmCostTracker::Ledger::Call.with_cost.count).to eq(1)
    expect(LlmCostTracker::Ledger::Call.without_cost.count).to eq(1)
    expect(LlmCostTracker::Ledger::Call.unknown_pricing.first.model).to eq("unknown-chat-model")
  end

  it "aggregates latency by model and provider" do
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      latency_ms: 100
    )
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5,
      latency_ms: 300
    )

    expect(LlmCostTracker::Ledger::Call.with_latency.count).to eq(2)
    expect(LlmCostTracker::Ledger::Call.average_latency_ms).to eq(200.0)
    expect(LlmCostTracker::Ledger::Call.latency_by_model).to eq("gpt-4o" => 200.0)
    expect(LlmCostTracker::Ledger::Call.latency_by_provider).to eq("openai" => 200.0)
  end

  it "reports missing latency as a current schema error" do
    ActiveRecord::Base.connection.remove_column(:llm_api_calls, :latency_ms)
    LlmCostTracker::Ledger::Call.reset_column_information

    expect(LlmCostTracker::Ledger::Schema::Calls.current_schema?).to be false
    expect(LlmCostTracker::Ledger::Schema::Calls.missing_current_schema_columns).to include("latency_ms")
    expect(LlmCostTracker::Ledger::Schema::Calls.current_schema_errors.join).to include("missing columns: latency_ms")
  end

  it "raises when ActiveRecord storage fails" do
    require "llm_cost_tracker/ledger"

    allow(LlmCostTracker::Ingestion::Inbox).to receive(:save)
      .and_raise(ActiveRecord::StatementInvalid, "database down")

    expect do
      track_and_flush(
        provider: :openai,
        model: "gpt-4o",
        input_tokens: 10,
        output_tokens: 5
      )
    end.to raise_error(ActiveRecord::StatementInvalid, /database down/)
  end

  it "returns daily cost keys as strings across adapters" do
    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 5
    )

    expect(LlmCostTracker::Ledger::Call.daily_costs.keys).to all(be_a(String))
  end

  it "builds a JSONB containment query for PostgreSQL JSONB tag columns" do
    connection = LlmCostTracker::Ledger::Call.connection
    allow(LlmCostTracker::Ledger::Schema::Adapter).to receive(:postgresql?).with(connection).and_return(true)

    sql = LlmCostTracker::Ledger::Call.by_tags(user_id: 42, feature: "chat").to_sql

    expect(sql).to include("tags @>")
    expect(sql).to include('{"user_id":"42","feature":"chat"}')
  end

  it "builds a JSON_CONTAINS query for MySQL JSON tag columns" do
    connection = LlmCostTracker::Ledger::Call.connection
    allow(LlmCostTracker::Ledger::Schema::Adapter).to receive(:postgresql?).with(connection).and_return(false)

    sql = LlmCostTracker::Ledger::Call.by_tags(user_id: 42, feature: "chat").to_sql

    expect(sql).to include("JSON_CONTAINS(tags,")
    expect(sql).to include('{"user_id":"42","feature":"chat"}')
  end

  it "builds MySQL-family tag value SQL" do
    %w[Mysql2 Trilogy MariaDB].each do |adapter_name|
      connection = LlmCostTracker::Ledger::Call.connection
      allow(connection).to receive(:adapter_name).and_return(adapter_name)
      allow(LlmCostTracker::Ledger::Schema::Adapter).to receive(:postgresql?).with(connection).and_return(false)
      allow(LlmCostTracker::Ledger::Schema::Adapter).to receive(:mysql?).with(connection).and_return(true)

      sql = LlmCostTracker::Ledger::Call.tag_value_expression("user_id")

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

    track_and_flush(
      provider: :openai,
      model: "gpt-4o",
      input_tokens: 1_000,
      output_tokens: 0
    )

    expect(LlmCostTracker::Ledger::Call.total_cost).to eq(0.0025)
    expect(budget_data[:monthly_total]).to eq(0.0025)
  end

  it "notifies once when :notify first crosses the monthly budget" do
    budget_totals = []

    LlmCostTracker.configure do |config|
      config.monthly_budget = 0.004
      config.on_budget_exceeded = ->(data) { budget_totals << data[:monthly_total] }
    end

    3.times do
      track_and_flush(
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
      track_and_flush(
        provider: :openai,
        model: "gpt-4o",
        input_tokens: 1_000,
        output_tokens: 0
      )
    end

    expect(budget_totals).to eq([0.005])
  end

  it "blocks before a request when the ActiveRecord monthly budget is exhausted" do
    track_and_flush(
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
    track_and_flush(
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
    track_and_flush(provider: :openai, model: "gpt-4o", input_tokens: 1_000, output_tokens: 0)

    allow(Time).to receive(:now).and_return(Time.utc(2026, 4, 17, 12))
    track_and_flush(provider: :openai, model: "gpt-4o", input_tokens: 1_000, output_tokens: 0)

    total = LlmCostTracker::Ledger::Period::Totals
            .call(%i[daily], time: Time.utc(2026, 4, 18, 23))
            .fetch(:daily)

    expect(total).to eq(0.0025)
  end
end
