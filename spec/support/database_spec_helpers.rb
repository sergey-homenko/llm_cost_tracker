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
    create_call_line_items_table(connection)
    create_call_tags_table(connection)
    create_call_rollups_table(connection)
    create_ingestion_tables(connection)
    create_provider_invoices_table(connection)
    create_lct_indexes(connection)
  end

  def tags_for_database(tags)
    tags.transform_keys(&:to_s).transform_values(&:to_s)
  end

  def drop_calls_table_with_dependents!
    connection = ActiveRecord::Base.connection
    %w[
      llm_cost_tracker_call_tags
      llm_cost_tracker_call_line_items
      llm_cost_tracker_calls
    ].each { |table| connection.drop_table(table, if_exists: true, force: :cascade) }
  end

  def create_call_tag_rows(call, tags)
    return if tags.nil? || tags.empty?

    rows = tags.map do |key, value|
      stored = value.is_a?(Hash) ? JSON.generate(value) : value.to_s
      { llm_cost_tracker_call_id: call.id, key: key.to_s, value: stored }
    end
    LlmCostTracker::CallTag.insert_all!(rows, record_timestamps: false, returning: false)
  end

  def drop_lct_tables!
    connection = ActiveRecord::Base.connection
    %w[
      llm_cost_tracker_ingestion_leases
      llm_cost_tracker_ingestion_inbox_entries
      llm_cost_tracker_provider_invoices
      llm_cost_tracker_call_tags
      llm_cost_tracker_call_line_items
      llm_cost_tracker_call_rollups
      llm_cost_tracker_calls
    ].each do |table|
      connection.drop_table(table, if_exists: true, force: :cascade)
    end
  end

  private

  def create_calls_table(connection)
    connection.create_table :llm_cost_tracker_calls, force: true do |table|
      table.string :event_id
      table.string :provider, null: false
      table.string :model, null: false
      LlmCostTracker::TokenUsage.members.each do |column|
        table.integer column, null: false, default: 0
      end
      table.decimal :total_cost, precision: 20, scale: 8
      table.integer :latency_ms
      table.boolean :stream, null: false, default: false
      table.string :usage_source
      table.string :provider_response_id
      table.string :provider_project_id
      table.string :provider_api_key_id
      table.string :provider_workspace_id
      table.boolean :batch, null: false, default: false
      table.string :pricing_mode
      table.string :cost_status
      if LlmCostTracker::Ledger::Schema::Adapter.postgresql?(connection)
        table.jsonb :pricing_snapshot
      elsif LlmCostTracker::Ledger::Schema::Adapter.mysql?(connection)
        table.json :pricing_snapshot
      else
        LlmCostTracker::Ledger::Schema::Adapter.ensure_supported!(connection)
      end
      table.datetime :tracked_at, null: false

      table.timestamps
    end
  end

  def create_call_line_items_table(connection)
    connection.create_table :llm_cost_tracker_call_line_items, force: true do |table|
      table.references :llm_cost_tracker_call,
                       null: false,
                       index: false,
                       foreign_key: { to_table: :llm_cost_tracker_calls, on_delete: :cascade }
      table.integer :position, null: false, default: 0, limit: 2
      table.string :kind, null: false
      table.string :direction, null: false
      table.string :modality, null: false
      table.string :cache_state, null: false, default: "none"
      table.decimal :quantity, precision: 30, scale: 10, null: false
      table.string :unit, null: false
      table.decimal :rate_amount, precision: 20, scale: 8
      table.decimal :rate_quantity, precision: 30, scale: 10, null: false, default: 1
      table.decimal :cost, precision: 20, scale: 8
      table.string :currency, null: false, default: "USD"
      table.string :cost_status, null: false, default: "unknown"
      table.string :pricing_basis
      table.string :price_key
      table.string :price_source
      table.string :price_source_version
      table.string :provider_field
      table.string :provider_item_id
      if LlmCostTracker::Ledger::Schema::Adapter.postgresql?(connection)
        table.jsonb :details, null: false, default: {}
      elsif LlmCostTracker::Ledger::Schema::Adapter.mysql?(connection)
        table.json :details, null: false
      else
        LlmCostTracker::Ledger::Schema::Adapter.ensure_supported!(connection)
      end

      table.datetime :created_at, null: false
    end
  end

  def create_call_tags_table(connection)
    connection.create_table :llm_cost_tracker_call_tags, force: true do |table|
      table.references :llm_cost_tracker_call,
                       null: false,
                       index: false,
                       foreign_key: { to_table: :llm_cost_tracker_calls, on_delete: :cascade }
      table.string :key, null: false
      table.text :value, null: false
    end
  end

  def create_call_rollups_table(connection)
    connection.create_table :llm_cost_tracker_call_rollups, force: true do |table|
      table.string :period, null: false
      table.date :period_start, null: false
      table.string :currency, null: false, default: "USD"
      table.decimal :total_cost, precision: 20, scale: 8, null: false, default: 0

      table.timestamps
    end
  end

  def create_provider_invoices_table(connection)
    connection.create_table :llm_cost_tracker_provider_invoices, force: true do |table|
      table.string :source, null: false
      table.date :period_start, null: false
      table.date :period_end, null: false
      table.string :external_id, null: false
      table.decimal :billed_amount, precision: 20, scale: 8
      table.string :currency, null: false, default: "USD"
      if LlmCostTracker::Ledger::Schema::Adapter.postgresql?(connection)
        table.jsonb :metadata, null: false, default: {}
      elsif LlmCostTracker::Ledger::Schema::Adapter.mysql?(connection)
        table.json :metadata, null: false
      else
        LlmCostTracker::Ledger::Schema::Adapter.ensure_supported!(connection)
      end
      table.datetime :imported_at, null: false
      table.timestamps
    end
  end

  def create_ingestion_tables(connection)
    connection.create_table :llm_cost_tracker_ingestion_inbox_entries, force: true do |table|
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

    connection.create_table :llm_cost_tracker_ingestion_leases, force: true do |table|
      table.string :name, null: false
      table.string :locked_by
      table.datetime :locked_until

      table.timestamps
    end
  end

  def create_lct_indexes(connection)
    connection.add_index :llm_cost_tracker_calls, :event_id, unique: true
    connection.add_index :llm_cost_tracker_calls, :tracked_at
    connection.add_index :llm_cost_tracker_calls, %i[provider tracked_at]
    connection.add_index :llm_cost_tracker_calls, %i[model tracked_at]
    connection.add_index :llm_cost_tracker_calls, :cost_status
    connection.add_index :llm_cost_tracker_calls, :provider_response_id
    connection.add_index :llm_cost_tracker_call_line_items, %i[llm_cost_tracker_call_id position]
    connection.add_index :llm_cost_tracker_call_line_items, :kind
    connection.add_index :llm_cost_tracker_call_tags, :llm_cost_tracker_call_id
    connection.add_index :llm_cost_tracker_call_tags, :key
    connection.add_index :llm_cost_tracker_call_rollups, %i[period period_start currency], unique: true
    connection.add_index :llm_cost_tracker_ingestion_inbox_entries, :event_id, unique: true
    connection.add_index :llm_cost_tracker_ingestion_inbox_entries, %i[tracked_at attempts]
    connection.add_index :llm_cost_tracker_ingestion_inbox_entries, %i[locked_at id]
    connection.add_index :llm_cost_tracker_ingestion_leases, :name, unique: true
    connection.add_index :llm_cost_tracker_provider_invoices, :external_id, unique: true
    connection.add_index :llm_cost_tracker_provider_invoices, %i[source period_start]
  end
end
