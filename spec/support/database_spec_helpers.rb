# frozen_string_literal: true

module LlmCostTrackerDatabaseSpecHelpers
  def establish_database_connection!
    LlmCostTrackerDatabase.establish!
    drop_lct_tables!
  end

  def disconnect_database!
    LlmCostTrackerDatabase.disconnect!
  end

  def add_tags_column(table)
    connection = ActiveRecord::Base.connection
    if LlmCostTracker::Ledger::DatabaseAdapter.postgresql?(connection)
      table.jsonb :tags, null: false, default: {}
    elsif LlmCostTracker::Ledger::DatabaseAdapter.mysql?(connection)
      table.json :tags, null: false
    else
      LlmCostTracker::Ledger::DatabaseAdapter.ensure_supported!(connection)
    end
  end

  def tags_for_database(tags, model: LlmCostTracker::Ledger::Call)
    normalized = tags.transform_keys(&:to_s).transform_values(&:to_s)
    model.tags_json_column? ? normalized : normalized.to_json
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
    LlmCostTracker::Ledger::Rollups.reset!
  end
end
