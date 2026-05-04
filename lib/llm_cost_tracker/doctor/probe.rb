# frozen_string_literal: true

require_relative "../ledger"

module LlmCostTracker
  class Doctor
    module Probe
      module_function

      def table_exists?(name)
        LlmCostTracker::Call.connection.data_source_exists?(name)
      rescue StandardError
        false
      end
    end
  end
end
