# frozen_string_literal: true

module LlmCostTracker
  module Ingestion
    class InboxEntry < ActiveRecord::Base
      MAX_ATTEMPTS_BEFORE_QUARANTINE = 5

      scope :pending, -> { where(attempts: ..(MAX_ATTEMPTS_BEFORE_QUARANTINE - 1)) }
    end
  end
end
