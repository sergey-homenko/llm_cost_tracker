# frozen_string_literal: true

module LlmCostTracker
  module Ingestion
    class InboxEntry < ActiveRecord::Base
      MAX_ATTEMPTS_BEFORE_QUARANTINE = 5
    end
  end
end
