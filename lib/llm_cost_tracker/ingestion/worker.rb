# frozen_string_literal: true

require "active_support/core_ext/kernel/reporting"
require "securerandom"

require_relative "inbox"
require_relative "batch"
require_relative "lease_claim"
require_relative "../logging"

module LlmCostTracker
  module Ingestion
    class Worker
      INTERVAL_SECONDS = 0.25
      IDLE_INTERVAL_SECONDS = 1.0
      MAX_IDLE_INTERVAL_SECONDS = 5.0
      LEASE_SECONDS = 10
      FLUSH_TIMEOUT_SECONDS = 10
      class << self
        def ensure_started
          thread = mutex.synchronize do
            reset_after_fork!
            unless @thread&.alive?
              @stop_requested = false
              @generation = @generation.to_i + 1
              generation = @generation
              @thread = Thread.new { run(generation) }
              @thread.name = "llm_cost_tracker_ingestor"
              @thread.report_on_exception = false
            end
            @thread
          end
          wake_thread(thread)
        end

        def flush!(timeout: nil, require_lease: false)
          Ingestion.ensure_current_schema!

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
          timeout ||= FLUSH_TIMEOUT_SECONDS
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

        def flush_timeout_seconds(timeout)
          return FLUSH_TIMEOUT_SECONDS if timeout.nil?

          numeric = Float(timeout)
          numeric.finite? && numeric.positive? ? numeric : FLUSH_TIMEOUT_SECONDS
        rescue ArgumentError, TypeError
          FLUSH_TIMEOUT_SECONDS
        end

        def ingest_once(require_lease: true)
          Ingestion.ensure_current_schema!
          batch = Ingestion::Batch.new(identity: identity)
          return 0 unless batch.claimable?
          return 0 if require_lease && !Ingestion::LeaseClaim.new(identity: identity, seconds: LEASE_SECONDS).acquire

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

        def release_connection!
          suppress(StandardError) { ActiveRecord::Base.connection_handler.clear_active_connections! }
        end
      end
    end
  end
end
