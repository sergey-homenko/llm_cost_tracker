# frozen_string_literal: true

require_relative "inbox"
require_relative "event"
require_relative "../ledger/store"

module LlmCostTracker
  module Ingestion
    class Batch
      BATCH_SIZE = 100
      LOCK_TIMEOUT_SECONDS = 30

      def initialize(identity:)
        @identity = identity
      end

      def ingest
        rows = claim
        return 0 if rows.empty?

        valid_rows, events = decode(rows)
        persist(valid_rows, events) if events.any?
        rows.size
      rescue StandardError => e
        rows_to_mark = valid_rows&.any? ? valid_rows : rows
        mark_failed(rows_to_mark, e) if rows_to_mark&.any?
        raise
      end

      def pending?
        Ingestion::Event.where("attempts < ?", Ingestion::Inbox::MAX_ATTEMPTS).exists?
      end

      def claimable?
        claimable_scope(Time.now.utc - LOCK_TIMEOUT_SECONDS).exists?
      end

      def mark_failed(rows, error)
        message = "#{error.class}: #{error.message}".byteslice(0, 1_000)
        now = Time.now.utc
        Ingestion::Event
          .where(id: rows.map(&:id), locked_by: identity)
          .update_all(last_error: message, locked_at: now, locked_by: nil, updated_at: now)
      rescue StandardError
        nil
      end

      private

      attr_reader :identity

      def claim
        now = Time.now.utc
        cutoff = now - LOCK_TIMEOUT_SECONDS
        Ingestion::Event.transaction do
          rows = claimable_scope(cutoff).order(:id).limit(BATCH_SIZE).lock.to_a
          ids = rows.map(&:id)
          next [] if ids.empty?

          updates = Ingestion::Event.sanitize_sql_array(
            ["locked_at = ?, locked_by = ?, attempts = attempts + 1, updated_at = ?", now, identity, now]
          )
          Ingestion::Event.where(id: ids).update_all(updates)
          Ingestion::Event.where(id: ids, locked_by: identity).order(:id).to_a
        end
      end

      def decode(rows)
        valid_rows = []
        events = []
        rows.each do |row|
          events << Ingestion::Inbox.event_from_row(row)
          valid_rows << row
        rescue StandardError => e
          mark_failed([row], e)
        end
        [valid_rows, events]
      end

      def persist(rows, events)
        LlmCostTracker::Ledger::Call.transaction do
          Ledger::Store.insert_many(events)
          Ingestion::Event.where(id: rows.map(&:id), locked_by: identity).delete_all
        end
      end

      def claimable_scope(cutoff)
        Ingestion::Event
          .where("attempts < ?", Ingestion::Inbox::MAX_ATTEMPTS)
          .where("locked_at IS NULL OR locked_at < ?", cutoff)
      end
    end
  end
end
