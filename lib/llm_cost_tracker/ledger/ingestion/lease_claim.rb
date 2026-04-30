# frozen_string_literal: true

require_relative "lease"

module LlmCostTracker
  class Ledger
    module Ingestion
      class LeaseClaim
        LEASE_NAME = "default"

        def initialize(identity:, seconds:)
          @identity = identity
          @seconds = seconds
        end

        def acquire
          now = Time.now.utc
          LlmCostTracker::Ledger::Ingestion::Lease.transaction do
            lease = LlmCostTracker::Ledger::Ingestion::Lease.lock.find_by(name: LEASE_NAME)
            lease ||= LlmCostTracker::Ledger::Ingestion::Lease.create!(name: LEASE_NAME)
            next false unless available?(lease, now)

            lease.update!(locked_by: identity, locked_until: now + seconds)
            true
          end
        rescue ActiveRecord::RecordNotUnique
          false
        end

        private

        attr_reader :identity, :seconds

        def available?(lease, now)
          lease.locked_by.nil? || lease.locked_by == identity || lease.locked_until.nil? || lease.locked_until < now
        end
      end
    end
  end
end
