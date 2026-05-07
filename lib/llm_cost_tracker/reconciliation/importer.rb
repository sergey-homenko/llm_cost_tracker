# frozen_string_literal: true

require "bigdecimal"
require "date"
require "json"

require_relative "import_result"
require_relative "../ledger/rollups"

module LlmCostTracker
  module Reconciliation
    class Importer
      REQUIRED_FIELDS = %i[external_id period_start period_end].freeze
      PROVIDER_API_SOURCES = %i[openai anthropic gemini openrouter].to_set.freeze

      def initialize(source:, imported_at:, strict_metadata: nil)
        @source = source.to_s
        @imported_at = imported_at
        @strict_metadata = strict_metadata.nil? ? PROVIDER_API_SOURCES.include?(source.to_sym) : strict_metadata
        raise ArgumentError, "source must be present" if @source.empty?
      end

      def call(rows)
        return ImportResult.empty if rows.nil? || rows.empty?

        normalized, errors = normalize_rows(rows)
        return ImportResult.new(inserted: 0, updated: 0, skipped: rows.size, errors: errors) if normalized.empty?

        existing = existing_external_ids(normalized.map { |row| row[:external_id] })
        rows_payload = normalized.map { |row| persistable_attributes(row) }
        ProviderInvoice.upsert_all(rows_payload, unique_by: :external_id, record_timestamps: true)

        inserted = normalized.count { |row| !existing.include?(row[:external_id]) }
        updated = normalized.size - inserted
        ImportResult.new(inserted: inserted, updated: updated, skipped: rows.size - normalized.size, errors: errors)
      end

      private

      attr_reader :source, :imported_at, :strict_metadata

      def normalize_rows(rows)
        errors = []
        normalized = rows.each_with_index.filter_map do |row, index|
          attrs = symbolize(row)
          missing = REQUIRED_FIELDS - attrs.keys
          if missing.any?
            errors << "row #{index}: missing #{missing.join(', ')}"
            next
          end
          attrs.merge(
            external_id: namespaced_external_id(attrs[:external_id]),
            period_start: parse_date(attrs[:period_start]),
            period_end: parse_date(attrs[:period_end]),
            metadata: parse_metadata(attrs[:metadata])
          )
        rescue ArgumentError => e
          errors << "row #{index}: #{e.message}"
          nil
        end
        [normalized, errors]
      end

      def existing_external_ids(external_ids)
        ProviderInvoice.where(external_id: external_ids).pluck(:external_id).to_set
      end

      def persistable_attributes(row)
        billed_amount = row[:billed_amount].nil? ? nil : BigDecimal(row[:billed_amount].to_s)
        {
          source: source,
          external_id: row[:external_id],
          period_start: row[:period_start],
          period_end: row[:period_end],
          billed_amount: billed_amount,
          currency: (row[:currency] || Ledger::Rollups::DEFAULT_CURRENCY).to_s,
          metadata: row[:metadata],
          imported_at: imported_at
        }
      end

      def namespaced_external_id(external_id)
        raw = external_id.to_s
        prefix = "#{source}:"
        raw.start_with?(prefix) ? raw : "#{prefix}#{raw}"
      end

      def symbolize(row)
        return row if row.is_a?(Hash) && row.keys.all?(Symbol)

        row.to_h.transform_keys { |key| key.to_s.to_sym }
      end

      def parse_date(value)
        return value if value.is_a?(Date)

        Date.parse(value.to_s)
      end

      def parse_metadata(metadata)
        return {} if metadata.nil?
        return metadata if metadata.is_a?(Hash)

        JSON.parse(metadata.to_s)
      rescue JSON::ParserError => e
        raise ArgumentError, "invalid metadata JSON: #{e.message}" if strict_metadata

        {}
      end
    end
  end
end
