# frozen_string_literal: true

require_relative "reconciliation/import_result"
require_relative "reconciliation/importer"

module LlmCostTracker
  module Reconciliation
    SUPPORTED_SOURCES = %i[openai anthropic gemini openrouter csv].freeze

    class << self
      def import(source:, rows:, imported_at: Time.now.utc)
        Importer.new(source: source, imported_at: imported_at).call(rows)
      end
    end
  end
end
