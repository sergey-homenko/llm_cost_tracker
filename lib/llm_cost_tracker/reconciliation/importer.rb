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
      FORGIVING_METADATA_SOURCES = %i[csv].to_set.freeze
      ENVELOPE_KEYS = %w[row_type meter authority match_basis].freeze

      def initialize(source:, imported_at:, window: nil, strict_metadata: nil, cursor: nil)
        @source = source.to_s
        @imported_at = imported_at
        @window = coerce_window(window)
        @cursor = cursor
        @strict_metadata = strict_metadata.nil? ? !FORGIVING_METADATA_SOURCES.include?(source.to_sym) : strict_metadata
        raise ArgumentError, "source must be present" if @source.empty?
      end

      def call(rows)
        ensure_reconciliation_installed!
        return ImportResult.empty if skippable?(rows)

        import_record = open_import_record
        result = perform_import(rows)
        complete_import_record(import_record, result)
        result.with(import_id: import_record&.id)
      rescue StandardError => e
        fail_import_record(import_record, e)
        raise
      end

      private

      attr_reader :source, :imported_at, :window, :cursor, :strict_metadata

      def skippable?(rows)
        (rows.nil? || rows.empty?) && cursor.nil?
      end

      def ensure_reconciliation_installed!
        return if ProviderInvoice.table_exists?

        raise Error,
              "llm_cost_tracker_provider_invoices table is missing; " \
              "run `rails generate llm_cost_tracker:reconciliation && rails db:migrate`"
      end

      def perform_import(rows)
        return ImportResult.empty if rows.nil? || rows.empty?

        normalized, errors = normalize_rows(rows)
        if normalized.empty?
          return ImportResult.new(inserted: 0, updated: 0, skipped: rows.size, errors: errors,
                                  import_id: nil)
        end

        existing = existing_external_ids(normalized.map { |row| row[:external_id] })
        rows_payload = normalized.map { |row| persistable_attributes(row) }
        ProviderInvoice.upsert_all(rows_payload, unique_by: :external_id, record_timestamps: true)

        inserted = normalized.count { |row| !existing.include?(row[:external_id]) }
        updated = normalized.size - inserted
        ImportResult.new(inserted: inserted, updated: updated, skipped: rows.size - normalized.size,
                         errors: errors, import_id: nil)
      end

      def open_import_record
        return nil unless tracking_table_present?

        ProviderInvoiceImport.create!(
          source: source,
          cursor: cursor,
          window_start: window&.first,
          window_end: window&.last,
          state: ProviderInvoiceImport::STATE_RUNNING,
          started_at: imported_at || Time.now.utc
        )
      end

      def complete_import_record(record, result)
        return unless record

        terminal_state = result.success? ? ProviderInvoiceImport::STATE_COMPLETED : ProviderInvoiceImport::STATE_FAILED
        record.update!(
          state: terminal_state,
          rows_imported: result.total_imported,
          finished_at: Time.now.utc,
          last_error: result.errors.first
        )
      end

      def fail_import_record(record, error)
        return unless record

        record.update!(
          state: ProviderInvoiceImport::STATE_FAILED,
          last_error: "#{error.class}: #{error.message}",
          finished_at: Time.now.utc
        )
      end

      def tracking_table_present?
        @tracking_table_present = ProviderInvoiceImport.table_exists? unless defined?(@tracking_table_present)
        @tracking_table_present
      end

      def normalize_rows(rows)
        errors = []
        normalized = rows.each_with_index.filter_map do |row, index|
          attrs = symbolize(row)
          missing = REQUIRED_FIELDS - attrs.keys
          if missing.any?
            errors << "row #{index}: missing #{missing.join(', ')}"
            next
          end
          period_start = parse_date(attrs[:period_start])
          period_end = parse_date(attrs[:period_end])
          next unless within_window?(period_start, period_end)

          attrs.merge(
            external_id: namespaced_external_id(attrs[:external_id]),
            period_start: period_start,
            period_end: period_end,
            metadata: parse_metadata(attrs[:metadata])
          )
        rescue ArgumentError => e
          errors << "row #{index}: #{e.message}"
          nil
        end
        [normalized, errors]
      end

      def within_window?(period_start, period_end)
        return true if window.nil?

        period_start <= window.last && period_end >= window.first
      end

      def coerce_window(window)
        return nil if window.nil?
        raise ArgumentError, "window must be a Range of dates" unless window.is_a?(Range)

        Range.new(parse_date(window.first), parse_date(window.last))
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
          imported_at: imported_at || Time.now.utc
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
        parsed = parse_metadata_payload(metadata)
        validate_envelope!(parsed) if strict_metadata
        parsed
      end

      def parse_metadata_payload(metadata)
        return {} if metadata.nil?
        return metadata if metadata.is_a?(Hash)

        JSON.parse(metadata.to_s)
      rescue JSON::ParserError => e
        raise ArgumentError, "invalid metadata JSON: #{e.message}" if strict_metadata

        {}
      end

      def validate_envelope!(metadata)
        keys = metadata.keys.map(&:to_s)
        missing = ENVELOPE_KEYS - keys
        return if missing.empty?

        raise ArgumentError, "metadata missing envelope keys: #{missing.join(', ')}"
      end
    end
  end
end
