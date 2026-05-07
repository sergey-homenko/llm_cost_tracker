# frozen_string_literal: true

require "active_record"

module LlmCostTracker
  class ProviderInvoiceImport < ActiveRecord::Base
    self.table_name = "llm_cost_tracker_provider_invoice_imports"

    STATE_RUNNING = "running"
    STATE_COMPLETED = "completed"
    STATE_FAILED = "failed"
    STATES = [STATE_RUNNING, STATE_COMPLETED, STATE_FAILED].freeze

    scope :for_source, ->(source) { where(source: source.to_s) }
    scope :running, -> { where(state: STATE_RUNNING) }
    scope :completed, -> { where(state: STATE_COMPLETED) }
    scope :failed, -> { where(state: STATE_FAILED) }
    scope :latest, -> { order(started_at: :desc, id: :desc) }

    def self.resume_cursor_for(source)
      for_source(source).latest.limit(1).pick(:cursor)
    end

    def self.last_completed_window_for(source)
      for_source(source).completed.latest.limit(1).pick(:window_start, :window_end)
    end
  end
end
