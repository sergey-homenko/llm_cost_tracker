# frozen_string_literal: true

require_relative "check"
require_relative "probe"
require_relative "../ledger"

module LlmCostTracker
  class Doctor
    class CallTagsCheck
      def call
        return unless Probe.table_exists?("llm_cost_tracker_calls")

        errors = LlmCostTracker::Ledger::Schema::CallTags.current_schema_errors
        return Check.new(:ok, "call tags", "llm_cost_tracker_call_tags exists") if errors.empty?

        Check.new(
          :error,
          "call tags",
          "current schema required; #{errors.join('; ')}; " \
          "run bin/rails generate llm_cost_tracker:install && bin/rails db:migrate"
        )
      end
    end
  end
end
