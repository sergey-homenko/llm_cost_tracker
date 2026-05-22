# frozen_string_literal: true

require "active_support/core_ext/kernel/reporting"
require "securerandom"

require_relative "inbox"
require_relative "batch"
require_relative "lease_claim"

module LlmCostTracker
  module Ingestion
    class Worker
      INTERVAL_SECONDS = 0.25
      IDLE_INTERVAL_SECONDS = 1.0
      MAX_IDLE_INTERVAL_SECONDS = 5.0
      LEASE_SECONDS = 10
      FLUSH_TIMEOUT_SECONDS = 10
      MUTEX = Mutex.new

      class << self
        def ensure_started
          return unless Ingestion.async?

          thread = MUTEX.synchronize do
            reset_after_fork!
            break @thread if @stop_requested || @thread&.alive?

            @generation = @generation.to_i + 1
            generation = @generation
            @thread = Thread.new { run(generation) }
            @thread.name = "llm_cost_tracker_ingestor"
            @thread.report_on_exception = false
            @thread
          end
          wake_thread(thread)
        end

        def flush!(timeout: nil, require_lease: false)
          return true unless Ingestion.async?

          Ingestion.ensure_current_schema!
          MUTEX.synchronize { reset_after_fork! }

          deadline = Time.now.utc + flush_timeout_seconds(timeout)
          loop do
            return true unless Ingestion::Batch.new(identity: identity).pending?
            return false if Time.now.utc >= deadline

            processed = ingest_once(require_lease: require_lease)
            next unless processed.zero?

            duration = [INTERVAL_SECONDS, deadline - Time.now.utc].min
            return false unless duration.positive?

            sleep(duration)
          end
        end

        def shutdown!(timeout: nil, drain: true)
          return true unless Ingestion.async?

          timeout ||= FLUSH_TIMEOUT_SECONDS
          thread = MUTEX.synchronize do
            @stop_requested = true
            @generation = @generation.to_i + 1
            @thread
          end
          wake_thread(thread)
          thread&.join(timeout)
          drain ? flush!(timeout: timeout, require_lease: true) : true
        rescue StandardError => e
          handle_error(e)
          false
        ensure
          MUTEX.synchronize do
            @thread = nil if @thread.equal?(thread) && !thread&.alive?
          end
        end

        def reset!
          thread = MUTEX.synchronize do
            @stop_requested = false
            @generation = @generation.to_i + 1
            thread = @thread
            @thread = nil
            @pid = nil
            @identity = nil
            thread
          end
          wake_thread(thread)
        end

        def flush_timeout_seconds(timeout)
          numeric = Float(timeout, exception: false)
          return FLUSH_TIMEOUT_SECONDS unless numeric&.finite? && numeric.positive?

          numeric
        end

        def ingest_once(require_lease: true)
          Ingestion.ensure_current_schema!
          MUTEX.synchronize { reset_after_fork! }
          batch = Ingestion::Batch.new(identity: identity)
          return 0 unless batch.claimable?
          return 0 if require_lease && !Ingestion::LeaseClaim.new(identity: identity, seconds: LEASE_SECONDS).acquire

          batch.ingest
        rescue StandardError => e
          handle_error(e)
          0
        end

        private

        def run(generation)
          idle_interval = IDLE_INTERVAL_SECONDS
          loop do
            break if MUTEX.synchronize { @stop_requested || generation != @generation }

            processed = Rails.application.executor.wrap { ingest_once }
            release_connection!
            if processed.zero?
              sleep(idle_interval)
              idle_interval = [idle_interval * 2, MAX_IDLE_INTERVAL_SECONDS].min
            else
              idle_interval = IDLE_INTERVAL_SECONDS
            end
          rescue StandardError => e
            handle_error(e)
            release_connection!
            sleep(idle_interval)
          end
        ensure
          release_connection!
          MUTEX.synchronize { @thread = nil if @thread.equal?(Thread.current) }
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

        def identity
          @identity ||= "pid-#{Process.pid}-#{SecureRandom.hex(6)}"
        end

        def handle_error(error)
          Logging.warn("ActiveRecord ingestor failed: #{error.class}: #{error.message}")
        end

        def release_connection!
          suppress(StandardError) { ActiveRecord::Base.connection_handler.clear_active_connections! }
        end
      end
    end
  end
end
