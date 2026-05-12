# frozen_string_literal: true

module LlmCostTracker
  class ProviderInvoiceImport < ActiveRecord::Base
    STATE_RUNNING = "running"
    STATE_COMPLETED = "completed"
    STATE_FAILED = "failed"
    STATES = [STATE_RUNNING, STATE_COMPLETED, STATE_FAILED].freeze

    scope :for_source, ->(source) { where(source: source.to_s) }
    scope :for_provider, ->(provider) { where(provider: provider.to_s) }
    scope :running, -> { where(state: STATE_RUNNING) }
    scope :completed, -> { where(state: STATE_COMPLETED) }
    scope :failed, -> { where(state: STATE_FAILED) }
    scope :latest, -> { order(started_at: :desc, id: :desc) }

    def self.resume_cursor_for(source, provider: nil)
      scope = for_source(source)
      scope = scope.for_provider(provider) if provider
      scope.latest.limit(1).pick(:cursor)
    end

    def self.last_completed_window_for(source, provider: nil)
      scope = for_source(source)
      scope = scope.for_provider(provider) if provider
      scope.completed.latest.limit(1).pick(:window_start, :window_end)
    end
  end
end
