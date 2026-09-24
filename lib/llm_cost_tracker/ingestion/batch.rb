# frozen_string_literal: true

require_relative "inbox"
require_relative "../budget"
require_relative "../ledger/store"

module LlmCostTracker
  module Ingestion
    class Batch
      BATCH_SIZE = 100
      LOCK_TIMEOUT_SECONDS = 30
      TRANSIENT_PERSIST_ERRORS = [
        ActiveRecord::Deadlocked,
        ActiveRecord::LockWaitTimeout,
        ActiveRecord::StatementTimeout,
        ActiveRecord::ConnectionNotEstablished,
        ActiveRecord::ConnectionFailed,
        ActiveRecord::QueryCanceled,
        LlmCostTracker::TransactionAbortedError
      ].freeze
      SPLIT_BATCH_ERRORS = [ActiveRecord::ConnectionFailed, ActiveRecord::QueryCanceled].freeze
      BATCH_TRANSIENT_ERRORS = (TRANSIENT_PERSIST_ERRORS - SPLIT_BATCH_ERRORS).freeze

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
        if rows_to_mark&.any?
          transient = valid_rows&.any? && TRANSIENT_PERSIST_ERRORS.any? { |klass| e.is_a?(klass) }
          mark_failed_with_message(rows_to_mark, error_message_for(e), decrement_attempts: transient)
        end
        raise
      end

      def pending?
        Ingestion::InboxEntry.pending.exists?
      end

      def claimable?
        claimable_scope(Time.now.utc - LOCK_TIMEOUT_SECONDS).exists?
      end

      def mark_failed_with_message(rows, message, decrement_attempts: false)
        now = Time.now.utc
        scope = Ingestion::InboxEntry.where(id: rows.map(&:id), locked_by: identity)
        if decrement_attempts
          scope.update_all(
            Ingestion::InboxEntry.sanitize_sql_array(
              ["last_error = ?, locked_at = ?, locked_by = NULL, " \
               "attempts = GREATEST(attempts - 1, 0), updated_at = ?", message, now, now]
            )
          )
        else
          scope.update_all(last_error: message, locked_at: now, locked_by: nil, updated_at: now)
          warn_on_quarantine(rows)
        end
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

        LlmCostTracker::Logging.warn(
          "Ingestion::Batch: #{quarantined.size} inbox row(s) reached " \
          "MAX_ATTEMPTS_BEFORE_QUARANTINE=#{threshold} and will be skipped " \
          "on the next claim cycle (ids: #{id_sample(quarantined)})"
        )
      end

      private

      attr_reader :identity

      def id_sample(rows)
        sample = rows.first(10).map(&:id).join(", ")
        rows.size > 10 ? "#{sample}..." : sample
      end

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
          events << Ledger::Storable.event(Ingestion::Inbox.event_from_row(row))
          valid_rows << row
        rescue StandardError => e
          failures[error_message_for(e)] << row
        end
        failures.each { |message, failed_rows| mark_failed_with_message(failed_rows, message) }
        [valid_rows, events]
      end

      def persist(rows, events)
        landed = []
        failed = Hash.new { |hash, message| hash[message] = [] }
        begin
          retried, fresh = rows.zip(events).partition { |row, _event| row.attempts.to_i.positive? }
          [fresh, retried].each { |pairs| persist_together(pairs, landed, failed) if pairs.any? }
        ensure
          failed.each { |message, failed_rows| report_unstored(failed_rows, message) }
          if landed.any?
            Ledger::Rollups.increment_safely!(landed)
            Budget.notify_persisted_safely!(landed)
          end
        end
      end

      def persist_together(pairs, landed, failed)
        return persist_alone(*pairs.first, landed, failed) if pairs.one?

        landed.concat(write(pairs))
      rescue *BATCH_TRANSIENT_ERRORS
        raise
      rescue StandardError
        pairs.each { |row, event| persist_alone(row, event, landed, failed) }
      end

      def persist_alone(row, event, landed, failed)
        landed.concat(write([[row, event]]))
      rescue *TRANSIENT_PERSIST_ERRORS
        raise
      rescue StandardError => e
        failed[error_message_for(e)] << row
      end

      def report_unstored(rows, message)
        LlmCostTracker::Logging.warn(
          "Ingestion::Batch: #{rows.size} inbox row(s) could not be stored and will be retried apart " \
          "from new rows (ids: #{id_sample(rows)}): #{message.byteslice(0, 300)}"
        )
        mark_failed_with_message(rows, message)
      end

      def write(pairs, retry_on_conflict: true)
        events = pairs.map(&:last)
        LlmCostTracker::Call.transaction do
          Ledger::Store.persist_records(events)
          Ingestion::InboxEntry.where(id: pairs.map { |row, _event| row.id }, locked_by: identity).delete_all
        end
        events
      rescue ActiveRecord::RecordNotUnique
        raise unless retry_on_conflict

        already_persisted = LlmCostTracker::Call.where(event_id: events.map(&:event_id)).pluck(:event_id)
        LlmCostTracker::Logging.warn(
          "Ingestion::Batch#persist: #{already_persisted.size} event_id(s) already in ledger; " \
          "skipped duplicates and persisted #{events.size - already_persisted.size} fresh event(s)"
        )
        duplicate_rows = pairs.filter_map { |row, event| row if already_persisted.include?(event.event_id) }
        Ingestion::InboxEntry.where(id: duplicate_rows.map(&:id), locked_by: identity).delete_all
        write(pairs.reject { |_row, event| already_persisted.include?(event.event_id) }, retry_on_conflict: false)
      end

      def claimable_scope(cutoff)
        Ingestion::InboxEntry
          .pending
          .where("locked_at IS NULL OR locked_at < ?", cutoff)
      end
    end
  end
end
