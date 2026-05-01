# frozen_string_literal: true

module LlmCostTrackerDatabaseSpecHelpers
  def establish_database_connection!
    LlmCostTrackerDatabase.establish!
    drop_lct_tables!
  end

  def disconnect_database!
    LlmCostTrackerDatabase.disconnect!
  end

  def create_lct_tables!
    connection = ActiveRecord::Base.connection
    create_calls_table(connection)
    create_period_totals_table(connection)
    create_ingestion_tables(connection)
    create_lct_indexes(connection)
  end

  def tags_for_database(tags)
    tags.transform_keys(&:to_s).transform_values(&:to_s)
  end

  def drop_lct_tables!
    connection = ActiveRecord::Base.connection
    %w[
      llm_cost_tracker_ingestor_leases
      llm_cost_tracker_inbox_events
      llm_cost_tracker_period_totals
      llm_api_calls
    ].each do |table|
      connection.drop_table(table, if_exists: true)
    end
  end

  private

  def create_calls_table(connection)
    connection.create_table :llm_api_calls, force: true do |table|
      table.string :event_id
      table.string :provider, null: false
      table.string :model, null: false
      LlmCostTracker::TokenUsage::STORED_KEYS.each do |column|
        table.integer column, null: false, default: 0
      end
      LlmCostTracker::Pricing::COST_KEYS.each do |column|
        table.decimal column, precision: 20, scale: 8
      end
      table.integer :latency_ms
      table.boolean :stream, null: false, default: false
      table.string :usage_source
      table.string :provider_response_id
      table.string :pricing_mode
      if LlmCostTracker::Ledger::Schema::Adapter.postgresql?(connection)
        table.jsonb :tags, null: false, default: {}
      elsif LlmCostTracker::Ledger::Schema::Adapter.mysql?(connection)
        table.json :tags, null: false
      else
        LlmCostTracker::Ledger::Schema::Adapter.ensure_supported!(connection)
      end
      table.datetime :tracked_at, null: false

      table.timestamps
    end
  end

  def create_period_totals_table(connection)
    connection.create_table :llm_cost_tracker_period_totals, force: true do |table|
      table.string :period, null: false
      table.date :period_start, null: false
      table.decimal :total_cost, precision: 20, scale: 8, null: false, default: 0

      table.timestamps
    end
  end

  def create_ingestion_tables(connection)
    connection.create_table :llm_cost_tracker_inbox_events, force: true do |table|
      table.string :event_id, null: false
      table.decimal :total_cost, precision: 20, scale: 8
      table.datetime :tracked_at, null: false
      table.text :payload, null: false
      table.datetime :locked_at
      table.string :locked_by
      table.integer :attempts, null: false, default: 0
      table.text :last_error

      table.timestamps
    end

    connection.create_table :llm_cost_tracker_ingestor_leases, force: true do |table|
      table.string :name, null: false
      table.string :locked_by
      table.datetime :locked_until

      table.timestamps
    end
  end

  def create_lct_indexes(connection)
    connection.add_index :llm_api_calls, :event_id, unique: true
    connection.add_index :llm_api_calls, :tracked_at
    connection.add_index :llm_api_calls, %i[provider tracked_at]
    connection.add_index :llm_api_calls, %i[model tracked_at]
    connection.add_index :llm_api_calls, :provider_response_id
    connection.add_index :llm_api_calls, :tags, using: :gin if LlmCostTracker::Ledger::Schema::Adapter.postgresql?(connection)
    connection.add_index :llm_cost_tracker_period_totals, %i[period period_start], unique: true
    connection.add_index :llm_cost_tracker_inbox_events, :event_id, unique: true
    connection.add_index :llm_cost_tracker_inbox_events, :tracked_at
    connection.add_index :llm_cost_tracker_inbox_events, %i[locked_at id]
    connection.add_index :llm_cost_tracker_ingestor_leases, :name, unique: true
  end
end
