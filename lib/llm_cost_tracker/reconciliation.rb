# frozen_string_literal: true

require_relative "reconciliation/import_result"
require_relative "reconciliation/importer"
require_relative "reconciliation/diff_result"
require_relative "reconciliation/diff"
require_relative "reconciliation/sources/openai_usage"
require_relative "reconciliation/sources/anthropic_usage"

module LlmCostTracker
  module Reconciliation
    SUPPORTED_SOURCES = %i[openai anthropic gemini csv].freeze

    class << self
      def import(source:, rows:, imported_at: Time.now.utc, window: nil, strict_metadata: nil)
        Importer.new(
          source: source,
          imported_at: imported_at,
          window: window,
          strict_metadata: strict_metadata
        ).call(rows)
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
