# frozen_string_literal: true

require_relative "../ledger"

module LlmCostTracker
  class Doctor
    module Probe
      def self.table_exists?(name)
        LlmCostTracker::Call.lease_connection.data_source_exists?(name)
      rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError,
             ActiveRecord::ConnectionFailed, ActiveRecord::StatementInvalid
        false
      end
    end
  end
end
