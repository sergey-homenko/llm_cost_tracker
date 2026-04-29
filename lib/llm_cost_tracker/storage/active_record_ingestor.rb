# frozen_string_literal: true

require "securerandom"

require_relative "../inbox_event"
require_relative "../logging"
require_relative "active_record_connection_cleanup"
require_relative "active_record_inbox"
require_relative "active_record_inbox_batch"
require_relative "active_record_ingestor_lease"

module LlmCostTracker
  module Storage
    class ActiveRecordIngestor
      INTERVAL_SECONDS = 0.25
      IDLE_INTERVAL_SECONDS = 1.0
      MAX_IDLE_INTERVAL_SECONDS = 5.0
      LEASE_SECONDS = 10
      FLUSH_TIMEOUT_SECONDS = 10
      class << self
        def ensure_started
          return unless ActiveRecordInbox.enabled?

          mutex.synchronize do
            reset_after_fork!
            return if @thread&.alive?

            @stop_requested = false
            @thread = Thread.new { run }
            @thread.name = "llm_cost_tracker_ingestor" if @thread.respond_to?(:name=)
            @thread.report_on_exception = false if @thread.respond_to?(:report_on_exception=)
          end
        end

        def flush!(timeout: FLUSH_TIMEOUT_SECONDS, require_lease: false)
          return true unless ActiveRecordInbox.enabled?

          deadline = Time.now.utc + timeout
          loop do
            return true unless pending_events?
            return false if Time.now.utc >= deadline

            processed = ingest_once(require_lease: require_lease)
            sleep([INTERVAL_SECONDS, deadline - Time.now.utc].min) if processed.zero?
          end
        end

        def shutdown!(timeout: FLUSH_TIMEOUT_SECONDS, drain: true)
          ActiveRecordInbox.reset!
          thread = mutex.synchronize do
            @stop_requested = true
            @thread
          end
          thread&.join([timeout, 1].min)
          drain ? flush!(timeout: timeout, require_lease: true) : true
        rescue StandardError => e
          handle_error(e)
          false
        ensure
          mutex.synchronize { @thread = nil if @thread.equal?(thread) }
        end

        def reset!
          mutex.synchronize do
            @stop_requested = true
            @thread = nil
            @pid = nil
            @identity = nil
          end
        end

        def ingest_once(require_lease: true)
          return 0 unless ActiveRecordInbox.enabled?
          return 0 unless claimable_events?
          return 0 if require_lease && !acquire_lease

          inbox_batch.ingest
        rescue StandardError => e
          handle_error(e)
          0
        end

        private

        def mutex
          @mutex ||= Mutex.new
        end

        def run
          idle_interval = IDLE_INTERVAL_SECONDS
          loop do
            break if stop_requested?

            processed = claimable_events? ? ingest_once : 0
            ActiveRecordConnectionCleanup.release!
            if processed.zero?
              sleep(idle_interval)
              idle_interval = [idle_interval * 2, MAX_IDLE_INTERVAL_SECONDS].min
            else
              idle_interval = IDLE_INTERVAL_SECONDS
            end
          rescue StandardError => e
            handle_error(e)
            ActiveRecordConnectionCleanup.release!
            sleep(idle_interval)
          end
        ensure
          ActiveRecordConnectionCleanup.release!
        end

        def stop_requested?
          mutex.synchronize { @stop_requested }
        end

        def reset_after_fork!
          return if @pid == Process.pid

          @pid = Process.pid
          @thread = nil
          @identity = nil
        end

        def identity = @identity ||= "pid-#{Process.pid}-#{SecureRandom.hex(6)}"

        def acquire_lease
          ActiveRecordIngestorLease.new(identity: identity, seconds: LEASE_SECONDS).acquire
        end

        def pending_events? = inbox_batch.pending?

        def claimable_events? = inbox_batch.claimable?

        def mark_failed(rows, error) = inbox_batch.mark_failed(rows, error)

        def inbox_batch = ActiveRecordInboxBatch.new(identity: identity)

        def handle_error(error)
          return if LlmCostTracker.configuration.storage_error_behavior == :ignore

          Logging.warn("ActiveRecord ingestor failed: #{error.class}: #{error.message}")
        end
      end
    end
  end
end
