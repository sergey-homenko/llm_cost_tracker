# frozen_string_literal: true

require_relative "reconciliation/import_result"
require_relative "reconciliation/importer"
require_relative "reconciliation/diff_result"
require_relative "reconciliation/diff"

module LlmCostTracker
  module Reconciliation
    SUPPORTED_SOURCES = %i[openai anthropic gemini openrouter csv].freeze

    class << self
      def import(source:, rows:, imported_at: Time.now.utc)
        Importer.new(source: source, imported_at: imported_at).call(rows)
      end

      def diff(source:, period_start:, period_end:, scope: {}, currency: nil)
        Diff.new(
          source: source,
          period_start: period_start,
          period_end: period_end,
          scope: scope,
          currency: currency
        ).call
      end
    end
  end
end
