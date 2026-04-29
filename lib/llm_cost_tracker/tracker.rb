# frozen_string_literal: true

require "securerandom"

require_relative "storage/dispatcher"

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

        model = normalize_model(model)
        usage = usage_data(input_tokens, output_tokens, metadata, pricing_mode)
        cost_data = cost_for_usage(provider, model, usage)

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

        stored = Storage::Dispatcher.save(event)
        Budget.check!(event) unless stored == false

        event
      end

      private

      def usage_data(input_tokens, output_tokens, metadata, pricing_mode)
        metadata = metadata.merge(pricing_mode: pricing_mode) unless pricing_mode.nil?

        EventMetadata.usage_data(
          input_tokens,
          output_tokens,
          metadata
        )
      end

      def cost_for_usage(provider, model, usage)
        Pricing.cost_for(
          provider: provider,
          model: model,
          input_tokens: usage[:input_tokens],
          output_tokens: usage[:output_tokens],
          cache_read_input_tokens: usage[:cache_read_input_tokens],
          cache_write_input_tokens: usage[:cache_write_input_tokens],
          pricing_mode: usage[:pricing_mode]
        )
      end

      def normalize_model(value) = value.to_s.strip.then { |model| model.empty? ? ParsedUsage::UNKNOWN_MODEL : model }

      def build_event(provider:, model:, usage:, cost_data:, metadata:, latency_ms:, stream:, usage_source:,
                      provider_response_id:)
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
          tags: sanitized_tags(metadata).freeze,
          latency_ms: normalized_latency_ms(latency_ms),
          stream: stream ? true : false,
          usage_source: normalized_usage_source(usage_source),
          provider_response_id: normalized_provider_response_id(provider_response_id),
          tracked_at: Time.now.utc
        )
      end

      def normalized_latency_ms(latency_ms) = latency_ms.nil? ? nil : [latency_ms.to_i, 0].max

      def sanitized_tags(metadata)
        LlmCostTracker::TagSanitizer.call(LlmCostTracker::TagContext.tags.merge(EventMetadata.tags(metadata)))
      end

      def normalized_usage_source(value)
        return nil if value.nil?

        symbol = value.to_sym
        USAGE_SOURCES.include?(symbol) ? symbol.to_s : nil
      end

      def normalized_provider_response_id(value) = value.nil? || value.to_s.empty? ? nil : value.to_s
    end
  end
end
