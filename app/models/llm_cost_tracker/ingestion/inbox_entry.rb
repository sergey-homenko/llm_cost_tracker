# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  module Ingestion
    class InboxEntry < ActiveRecord::Base
      MAX_ATTEMPTS_BEFORE_QUARANTINE = 5
    end
  end
end
