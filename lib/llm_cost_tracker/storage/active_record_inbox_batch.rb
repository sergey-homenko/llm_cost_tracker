# frozen_string_literal: true

require_relative "../inbox_event"
require_relative "active_record_inbox"
require_relative "active_record_store"

module LlmCostTracker
  module Storage
    class ActiveRecordInboxBatch
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

      def pending? = model.where("attempts < ?", ActiveRecordInbox::MAX_ATTEMPTS).exists?

      def claimable? = claimable_scope(Time.now.utc - LOCK_TIMEOUT_SECONDS).exists?

      def mark_failed(rows, error)
        message = "#{error.class}: #{error.message}".byteslice(0, 1_000)
        now = Time.now.utc
        model
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
        model.transaction do
          rows = claimable_scope(cutoff).order(:id).limit(BATCH_SIZE).lock.to_a
          ids = rows.map(&:id)
          next [] if ids.empty?

          updates = model.sanitize_sql_array(
            ["locked_at = ?, locked_by = ?, attempts = attempts + 1, updated_at = ?", now, identity, now]
          )
          model.where(id: ids).update_all(updates)
          model.where(id: ids, locked_by: identity).order(:id).to_a
        end
      end

      def decode(rows)
        valid_rows = []
        events = []
        rows.each do |row|
          events << ActiveRecordInbox.event_from_row(row)
          valid_rows << row
        rescue StandardError => e
          mark_failed([row], e)
        end
        [valid_rows, events]
      end

      def persist(rows, events)
        LlmCostTracker::LlmApiCall.transaction do
          ActiveRecordStore.insert_many(events)
          model.where(id: rows.map(&:id), locked_by: identity).delete_all
        end
      end

      def claimable_scope(cutoff)
        model
          .where("attempts < ?", ActiveRecordInbox::MAX_ATTEMPTS)
          .where("locked_at IS NULL OR locked_at < ?", cutoff)
      end

      def model = LlmCostTracker::InboxEvent
    end
  end
end
