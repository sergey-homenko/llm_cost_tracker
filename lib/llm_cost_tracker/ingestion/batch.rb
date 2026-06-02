# frozen_string_literal: true

require_relative "inbox"
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
        mark_failed_with_message(rows_to_mark, error_message_for(e)) if rows_to_mark&.any?
        raise
      end

      def pending?
        Ingestion::InboxEntry.pending.exists?
      end

      def claimable?
        claimable_scope(Time.now.utc - LOCK_TIMEOUT_SECONDS).exists?
      end

      def mark_failed_with_message(rows, message)
        now = Time.now.utc
        Ingestion::InboxEntry
          .where(id: rows.map(&:id), locked_by: identity)
          .update_all(last_error: message, locked_at: now, locked_by: nil, updated_at: now)
        warn_on_quarantine(rows)
      rescue StandardError => e
        LlmCostTracker::Logging.warn(
          "Inbox mark_failed_with_message failed for #{rows.size} rows: #{e.class}: #{e.message} " \
          "(attempted message: #{message.to_s.byteslice(0, 200)})"
        )
        nil
      end

      def error_message_for(error)
        "#{error.class}: #{error.message}".byteslice(0, 1_000)
      end

      def warn_on_quarantine(rows)
        threshold = Ingestion::InboxEntry::MAX_ATTEMPTS_BEFORE_QUARANTINE
        quarantined = rows.select { |row| row.attempts.to_i + 1 >= threshold }
        return if quarantined.empty?

        sample = quarantined.first(10).map(&:id).join(", ")
        sample += "..." if quarantined.size > 10
        LlmCostTracker::Logging.warn(
          "Ingestion::Batch: #{quarantined.size} inbox row(s) reached " \
          "MAX_ATTEMPTS_BEFORE_QUARANTINE=#{threshold} and will be skipped " \
          "on the next claim cycle (ids: #{sample})"
        )
      end

      private

      attr_reader :identity

      def claim
        now = Time.now.utc
        cutoff = now - LOCK_TIMEOUT_SECONDS
        Ingestion::InboxEntry.transaction do
          rows = claimable_scope(cutoff).order(:id).limit(BATCH_SIZE).lock.to_a
          next [] if rows.empty?

          updates = Ingestion::InboxEntry.sanitize_sql_array(
            ["locked_at = ?, locked_by = ?, attempts = attempts + 1, updated_at = ?", now, identity, now]
          )
          Ingestion::InboxEntry.where(id: rows.map(&:id)).update_all(updates)
          rows
        end
      end

      def decode(rows)
        valid_rows = []
        events = []
        failures = Hash.new { |h, k| h[k] = [] }
        rows.each do |row|
          events << Ingestion::Inbox.event_from_row(row)
          valid_rows << row
        rescue StandardError => e
          failures[error_message_for(e)] << row
        end
        failures.each { |message, failed_rows| mark_failed_with_message(failed_rows, message) }
        [valid_rows, events]
      end

      def persist(rows, events, retry_on_conflict: true)
        LlmCostTracker::Call.transaction do
          Ledger::Store.insert(events)
          Ingestion::InboxEntry.where(id: rows.map(&:id), locked_by: identity).delete_all
        end
      rescue ActiveRecord::RecordNotUnique
        raise unless retry_on_conflict

        already_persisted = LlmCostTracker::Call.where(event_id: events.map(&:event_id)).pluck(:event_id)
        fresh_events = events.reject { |event| already_persisted.include?(event.event_id) }
        LlmCostTracker::Logging.warn(
          "Ingestion::Batch#persist: #{already_persisted.size} event_id(s) already in ledger; " \
          "skipped duplicates and persisted #{fresh_events.size} fresh event(s)"
        )
        persist(rows, fresh_events, retry_on_conflict: false)
      end

      def claimable_scope(cutoff)
        Ingestion::InboxEntry
          .pending
          .where("locked_at IS NULL OR locked_at < ?", cutoff)
      end
    end
  end
end
