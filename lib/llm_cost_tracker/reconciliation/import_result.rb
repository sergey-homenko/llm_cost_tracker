# frozen_string_literal: true

module LlmCostTracker
  module Reconciliation
    ImportResult = Data.define(:inserted, :updated, :skipped, :errors, :import_id) do
      def self.empty
        new(inserted: 0, updated: 0, skipped: 0, errors: [], import_id: nil)
      end

      def total_imported
        inserted + updated
      end

      def success?
        errors.empty?
      end
    end
  end
end
