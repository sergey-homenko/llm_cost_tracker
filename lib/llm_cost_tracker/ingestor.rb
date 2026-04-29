# frozen_string_literal: true

require "securerandom"

require_relative "connection_cleanup"
require_relative "inbox"
require_relative "inbox_batch"
require_relative "inbox_event"
require_relative "ingestor_lease_claim"
require_relative "logging"

module LlmCostTracker
  class Ingestor
    INTERVAL_SECONDS = 0.25
    IDLE_INTERVAL_SECONDS = 1.0
    MAX_IDLE_INTERVAL_SECONDS = 5.0
    LEASE_SECONDS = 10
    FLUSH_TIMEOUT_SECONDS = 10
    class << self
      def ensure_started
        return unless Inbox.enabled?

        thread = mutex.synchronize do
          reset_after_fork!
          unless @thread&.alive?
            @stop_requested = false
            @generation = @generation.to_i + 1
            generation = @generation
            @thread = Thread.new { run(generation) }
            @thread.name = "llm_cost_tracker_ingestor" if @thread.respond_to?(:name=)
            @thread.report_on_exception = false if @thread.respond_to?(:report_on_exception=)
          end
          @thread
        end
        wake_thread(thread)
      end

      def flush!(timeout: FLUSH_TIMEOUT_SECONDS, require_lease: false)
        return true unless Inbox.enabled?

        deadline = Time.now.utc + timeout
        loop do
          return true unless InboxBatch.new(identity: identity).pending?
          return false if Time.now.utc >= deadline

          processed = ingest_once(require_lease: require_lease)
          next unless processed.zero?

          duration = [INTERVAL_SECONDS, deadline - Time.now.utc].min
          return false unless duration.positive?

          sleep(duration)
        end
      end

      def shutdown!(timeout: FLUSH_TIMEOUT_SECONDS, drain: true)
        Inbox.reset!
        thread = mutex.synchronize do
          @stop_requested = true
          @generation = @generation.to_i + 1
          @thread
        end
        wake_thread(thread)
        thread&.join([timeout, 1].min)
        drain ? flush!(timeout: timeout, require_lease: true) : true
      rescue StandardError => e
        handle_error(e)
        false
      ensure
        mutex.synchronize { @thread = nil if @thread.equal?(thread) }
      end

      def reset!
        thread = mutex.synchronize do
          @stop_requested = true
          @generation = @generation.to_i + 1
          thread = @thread
          @thread = nil
          @pid = nil
          @identity = nil
          thread
        end
        wake_thread(thread)
      end

      def ingest_once(require_lease: true)
        return 0 unless Inbox.enabled?

        batch = InboxBatch.new(identity: identity)
        return 0 unless batch.claimable?
        return 0 if require_lease && !IngestorLeaseClaim.new(identity: identity, seconds: LEASE_SECONDS).acquire

        batch.ingest
      rescue StandardError => e
        handle_error(e)
        0
      end

      private

      def mutex
        @mutex ||= Mutex.new
      end

      def run(generation)
        idle_interval = IDLE_INTERVAL_SECONDS
        loop do
          break if mutex.synchronize { @stop_requested || generation != @generation }

          processed = executor_wrap { ingest_once }
          ConnectionCleanup.release!
          if processed.zero?
            sleep(idle_interval)
            idle_interval = [idle_interval * 2, MAX_IDLE_INTERVAL_SECONDS].min
          else
            idle_interval = IDLE_INTERVAL_SECONDS
          end
        rescue StandardError => e
          handle_error(e)
          ConnectionCleanup.release!
          sleep(idle_interval)
        end
      ensure
        ConnectionCleanup.release!
        mutex.synchronize { @thread = nil if @thread.equal?(Thread.current) }
      end

      def reset_after_fork!
        return if @pid == Process.pid

        @pid = Process.pid
        @thread = nil
        @identity = nil
      end

      def wake_thread(thread)
        thread&.wakeup if thread&.alive?
      rescue ThreadError
        nil
      end

      def executor_wrap(&)
        executor = rails_executor
        return yield unless executor

        executor.wrap(&)
      end

      def rails_executor
        Rails.application.try(:executor)
      rescue StandardError
        nil
      end

      def identity
        @identity ||= "pid-#{Process.pid}-#{SecureRandom.hex(6)}"
      end

      def handle_error(error)
        Logging.warn("ActiveRecord ingestor failed: #{error.class}: #{error.message}")
      end
    end
  end
end
