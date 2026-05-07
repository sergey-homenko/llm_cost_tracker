# frozen_string_literal: true

require_relative "reconciliation/masking"
require_relative "reconciliation/import_result"
require_relative "reconciliation/importer"
require_relative "reconciliation/diff_result"
require_relative "reconciliation/diff"
require_relative "reconciliation/sources/fingerprint"
require_relative "reconciliation/sources/openai_usage"
require_relative "reconciliation/sources/anthropic_usage"

module LlmCostTracker
  module Reconciliation
    SUPPORTED_SOURCES = %i[openai anthropic gemini csv].freeze
    DEFAULT_THRESHOLD_PERCENT = 5.0
    INVOICE_FRESHNESS_DAYS = 14

    class << self
      def import(source:, rows:, imported_at: nil, window: nil, strict_metadata: nil, cursor: nil)
        Importer.new(
          source: source,
          imported_at: imported_at,
          window: window,
          strict_metadata: strict_metadata,
          cursor: cursor
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
