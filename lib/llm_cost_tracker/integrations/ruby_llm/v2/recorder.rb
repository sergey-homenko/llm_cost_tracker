# frozen_string_literal: true

module LlmCostTracker
  module Integrations
    module RubyLlm
      module V2
        module Recorder
          RECORDED = ObjectSpace::WeakKeyMap.new

          class << self
            def record(attempt)
              event = attempt.event
              return unless event

              LlmCostTracker::Tracker.record(event: event, latency_ms: attempt.latency_ms, **tags_for(attempt.usage))
            end

            def record_all(attempts) = attempts.filter_map { |attempt| caller_error { record(attempt) } }

            def record_batch(batch, results, frame)
              errors = Array(results).each_with_index.filter_map do |result, index|
                next if result.nil? || RECORDED.key?(result)

                caller_error do
                  record_batch_result(batch, result, index, frame)
                  RECORDED[result] = true
                end
              end
              raise errors.first if errors.any?
            end

            def tags_for(payload)
              context = LlmCostTracker::Tags::Context.tags
              tagged = context.any? { |key, value| key.to_s == "run_id" && !value.to_s.empty? }
              run_id = payload[:workflow_id] unless tagged
              { context_tags: context,
                metadata: { run_id: run_id }.compact.merge(payload.slice(:workflow_name, :workflow_step_name).compact) }
            end

            private

            def caller_error(&)
              V2.record_safely(&)
              nil
            rescue *CALLER_ERRORS => e
              e
            end

            def record_batch_result(batch, result, index, frame)
              usage = batch_usage(batch, result, index)
              base = frame.provider&.api_base || RubyLLM.config.try("#{batch.provider}_api_base")
              event = Attempt.batch_event(usage, result, base)
              return unless event

              id = event.provider_response_id || "#{batch.id}/#{index}"
              return if Call.already_recorded?(provider: event.provider, provider_response_id: id)

              V2.record_once(event.with(provider_response_id: id), **tags_for(frame.workflow.to_h))
            end

            def batch_usage(batch, result, index)
              { operation: result.is_a?(RubyLLM::Embedding) ? :embedding : :chat, provider: batch.provider,
                model: result.model || batch.chats.to_a[index]&.model&.id, status: :succeeded, tokens: result.tokens }
            end
          end
        end
      end
    end
  end
end
