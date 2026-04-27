# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Integrations
    module Anthropic
      extend Base

      class << self
        def integration_name = :anthropic

        def minimum_version = "1.36.0"

        def version_constant = "Anthropic::VERSION"

        def patch_targets
          [
            patch_target("Anthropic::Resources::Messages", with: MessagesPatch, methods: :create),
            patch_target(
              "Anthropic::Resources::Beta::Messages",
              with: MessagesPatch,
              methods: :create,
              optional: true
            )
          ]
        end

        def record_message(message, request:, latency_ms:)
          return unless active?

          record_safely do
            usage = ObjectReader.first(message, :usage)
            next unless usage

            input_tokens = ObjectReader.first(usage, :input_tokens)
            output_tokens = ObjectReader.first(usage, :output_tokens)
            next if input_tokens.nil? && output_tokens.nil?

            LlmCostTracker::Tracker.record(
              provider: "anthropic",
              model: ObjectReader.first(message, :model) || request[:model],
              input_tokens: ObjectReader.integer(input_tokens),
              output_tokens: ObjectReader.integer(output_tokens),
              latency_ms: latency_ms,
              usage_source: :sdk_response,
              provider_response_id: ObjectReader.first(message, :id),
              metadata: usage_metadata(usage)
            )
          end
        end

        def usage_metadata(usage)
          {
            cache_read_input_tokens: ObjectReader.integer(ObjectReader.first(usage, :cache_read_input_tokens)),
            cache_write_input_tokens: ObjectReader.integer(ObjectReader.first(usage, :cache_creation_input_tokens)),
            hidden_output_tokens: hidden_output_tokens(usage)
          }
        end

        def hidden_output_tokens(usage)
          ObjectReader.integer(
            ObjectReader.first(usage, :thinking_tokens, :thinking_output_tokens) ||
            ObjectReader.nested(usage, :output_tokens_details, :reasoning_tokens)
          )
        end
      end

      module MessagesPatch
        def create(*args, **kwargs)
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          LlmCostTracker::Integrations::Anthropic.enforce_budget!
          message = super
          LlmCostTracker::Integrations::Anthropic.record_message(
            message,
            request: LlmCostTracker::Integrations::Anthropic.request_params(args, kwargs),
            latency_ms: LlmCostTracker::Integrations::Anthropic.elapsed_ms(started_at)
          )
          message
        end
      end
    end
  end
end
