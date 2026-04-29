# frozen_string_literal: true

require "securerandom"

require_relative "ledger"

module LlmCostTracker
  class Tracker
    EVENT_NAME = "llm_request.llm_cost_tracker"

    USAGE_SOURCES = %i[response stream_final sdk_response ruby_llm manual unknown].freeze

    class << self
      def enforce_budget!
        return unless LlmCostTracker.configuration.enabled

        Budget.enforce!
      end

      def record(provider:, model:, input_tokens:, output_tokens:, latency_ms: nil, stream: false,
                 usage_source: nil, provider_response_id: nil, pricing_mode: nil, metadata: {})
        return unless LlmCostTracker.configuration.enabled

        model = model.to_s.strip.then { |normalized| normalized.empty? ? ParsedUsage::UNKNOWN_MODEL : normalized }
        metadata = metadata.merge(pricing_mode: pricing_mode) unless pricing_mode.nil?
        usage = EventMetadata.usage_data(input_tokens, output_tokens, metadata)
        cost_data = Pricing.cost_for(
          provider: provider,
          model: model,
          input_tokens: usage[:input_tokens],
          output_tokens: usage[:output_tokens],
          cache_read_input_tokens: usage[:cache_read_input_tokens],
          cache_write_input_tokens: usage[:cache_write_input_tokens],
          pricing_mode: usage[:pricing_mode]
        )

        UnknownPricing.handle!(model) unless cost_data

        event = build_event(
          provider: provider,
          model: model,
          usage: usage,
          cost_data: cost_data,
          metadata: metadata,
          latency_ms: latency_ms,
          stream: stream,
          usage_source: usage_source,
          provider_response_id: provider_response_id
        )

        ActiveSupport::Notifications.instrument(EVENT_NAME, event.to_h)

        Ledger.save(event)
        Budget.check!(event)

        event
      end

      private

      def build_event(provider:, model:, usage:, cost_data:, metadata:, latency_ms:, stream:, usage_source:,
                      provider_response_id:)
        usage_source = if usage_source.nil?
                         nil
                       else
                         symbol = usage_source.to_sym
                         USAGE_SOURCES.include?(symbol) ? symbol.to_s : nil
                       end
        Event.new(
          event_id: SecureRandom.uuid,
          provider: provider,
          model: model,
          input_tokens: usage[:input_tokens],
          output_tokens: usage[:output_tokens],
          total_tokens: usage[:total_tokens],
          cache_read_input_tokens: usage[:cache_read_input_tokens],
          cache_write_input_tokens: usage[:cache_write_input_tokens],
          hidden_output_tokens: usage[:hidden_output_tokens],
          pricing_mode: usage[:pricing_mode],
          cost: cost_data,
          tags: LlmCostTracker::TagSanitizer.call(
            LlmCostTracker::TagContext.tags.merge(EventMetadata.tags(metadata))
          ).freeze,
          latency_ms: latency_ms.nil? ? nil : [latency_ms.to_i, 0].max,
          stream: stream ? true : false,
          usage_source: usage_source,
          provider_response_id: provider_response_id.to_s.presence,
          tracked_at: Time.now.utc
        )
      end
    end
  end
end
