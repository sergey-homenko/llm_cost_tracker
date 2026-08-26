# frozen_string_literal: true

module LlmCostTrackerReset
  def self.call
    LlmCostTracker::Ingestion::Worker.shutdown!(drain: false)

    pool = LlmCostTracker::Ingestion::Pool
    pool.instance_variable_get(:@pool)&.disconnect!
    pool.instance_variable_set(:@pool, nil)
    pool.instance_variable_set(:@handler, nil)

    LlmCostTracker.instance_variable_set(:@configuration, LlmCostTracker::Configuration.new)
    LlmCostTracker::Pricing::Registry.reset!
    LlmCostTracker::Pricing::Unknown.instance_variable_get(:@warned_models)&.clear
    LlmCostTracker::Ledger::Rollups.instance_variable_set(:@missing_table_warned, false)
    LlmCostTracker::Budget::PerTag.instance_variable_set(:@missing_columns_warned, false)
    LlmCostTracker::Budget::PerTag.instance_variable_get(:@slow_keys)&.clear

    worker = LlmCostTracker::Ingestion::Worker
    worker.instance_variable_set(:@thread, nil)
    worker.instance_variable_set(:@stop_requested, false)
    worker.instance_variable_set(:@generation, nil)
    worker.instance_variable_set(:@pid, nil)
    worker.instance_variable_set(:@identity, nil)

    ActiveSupport::IsolatedExecutionState[LlmCostTracker::Tags::Context::KEY] = []
    LlmCostTracker::Dashboard::SetupState.reset!
  end
end
