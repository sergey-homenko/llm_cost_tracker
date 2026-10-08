# frozen_string_literal: true

require "active_support/notifications"
require_relative "../base"
require_relative "v2/attempt"
require_relative "v2/frame"
require_relative "v2/recorder"
require_relative "v2/seams"

module LlmCostTracker
  module Integrations
    module RubyLlm
      module V2
        extend Base

        minimum_version "2.0.0"
        maximum_version "3.0.0"

        OPERATIONS = %i[chat embedding image transcription moderation speech ocr rerank judgment].freeze
        JOBS = %w[batch.ruby_llm video_job.ruby_llm research_job.ruby_llm].freeze
        EVENTS = [*OPERATIONS, :compaction, :request, :usage].map { |name| "#{name}.ruby_llm" }.concat(JOBS).freeze
        CACHE_CREATED = :llm_cost_tracker_ruby_llm_cache_created

        class << self
          def integration_name = :ruby_llm

          def install
            validate_contract!
            Logging.warn(untested_version_message) if untested_version?
            @subscriptions ||= EVENTS.map { |name| ActiveSupport::Notifications.subscribe(name, self) }
            RubyLLM.config.instrumenter ||= ActiveSupport::Notifications
            Seams.bridge
          end

          def status
            name = integration_name.to_s
            warning = install_warning
            return Check.new(:warn, name, warning) if warning

            missing = Seams.missing
            return Check.new(:ok, name, "#{name} integration installed") if missing.empty?

            message = "#{name} integration installed, but these RubyLLM methods are missing, so what they carry " \
                      "is not read: #{missing.join(', ')}"
            Check.new(:warn, name, message)
          end

          def start(name, _id, payload)
            case name
            when "usage.ruby_llm" then nil
            when "request.ruby_llm" then start_request(payload)
            else start_operation(name, payload)
            end
          end

          def finish(name, _id, payload)
            case name
            when "usage.ruby_llm" then add_attempt(payload) unless %i[video research].include?(payload[:operation])
            when "request.ruby_llm" then Frame.current&.request_finished(payload)
            else finish_operation(payload)
            end
          end

          def observe(seam, value, protocol = nil)
            record_safely do
              next record_cache_storage(value) if seam == :parse_cache_response

              Frame.current&.observe(seam, value, protocol&.provider)
            end
          end

          def collect(batch)
            frame = Frame.open(batch, workflow: current_workflow)
            results = yield
            Recorder.record_batch(batch, results, frame) if active?
            results
          ensure
            Frame.discard(frame)
          end

          private

          def install_warning
            problems = version_problems + target_problems
            return "#{integration_name} integration cannot be installed: #{problems.join('; ')}" if problems.any?
            return untested_version_message if untested_version?
            return "#{integration_name} integration is enabled but not installed" unless @subscriptions

            instrumenter = RubyLLM.config.instrumenter
            return if instrumenter == ActiveSupport::Notifications

            "RubyLLM.config.instrumenter is #{instrumenter.inspect}, not ActiveSupport::Notifications, " \
              "so RubyLLM calls are not recorded"
          end

          def target_problems = defined?(RubyLLM.config) ? [] : ["RubyLLM is not loaded"]

          def current_workflow
            instrumentation = "RubyLLM::Support::Instrumentation".safe_constantize
            instrumentation.current_workflow if instrumentation.respond_to?(:current_workflow)
          end

          def start_operation(name, payload)
            return unless active?

            enforce_budget!(
              request: budget_request(payload),
              provider: payload[:provider].to_s,
              tags: (LlmCostTracker::Tracker.build_tags(**Recorder.tags_for(payload)) if payload[:workflow_id])
            )
            Frame.open(payload, compaction: name.start_with?("compaction")) if JOBS.exclude?(name)
          end

          def budget_request(payload)
            input = payload[:input_messages]&.map { |message| message.try(:content).then { |c| c.try(:text) || c } }
            { model: payload[:model], input: input || payload.values_at(:input, :prompt, :query) }
          end

          def finish_operation(payload)
            errors = Recorder.record_all(Frame.close(payload).flat_map(&:attempts))
            raise errors.first if errors.any? && !payload[:exception]
          end

          def start_request(payload)
            cache = payload[:method] == :post && payload[:url].to_s.end_with?("cachedContents")
            Thread.current[CACHE_CREATED] = (payload[:provider].to_s if cache)
            enforce_budget!(request: {}, provider: payload[:provider].to_s) if cache
            Frame.current&.request_started
          end

          def add_attempt(usage)
            if OPERATIONS.include?(usage[:operation])
              Frame.current&.add_attempt(usage)
            elsif active?
              record_safely { Recorder.record(Attempt.new(usage, {}, final: false)) }
            end
          end

          def record_cache_storage(data)
            event = Providers::Gemini::Parser.new.cache_storage_event(data) if Thread.current[CACHE_CREATED] && active?
            LlmCostTracker::Tracker.record(event: event.with(provider: Thread.current[CACHE_CREATED])) if event
          rescue LlmCostTracker::BudgetExceededError
            nil
          end
        end
      end
    end
  end
end
