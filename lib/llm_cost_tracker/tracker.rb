# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "securerandom"

require_relative "ledger"

module LlmCostTracker
  class Tracker
    EVENT_NAME = "llm_request.llm_cost_tracker"

    USAGE_SOURCES = %i[response stream_final sdk_response ruby_llm manual unknown].freeze
    TRACKING_METADATA_KEYS = (TokenUsage::COUNTER_KEYS.map(&:to_s) + %w[pricing_mode provider_response_id]).freeze

    class << self
      def enforce_budget!
        return unless LlmCostTracker.configuration.enabled

        Budget.enforce!
      end

      def record(provider:, model:, token_usage:, latency_ms: nil, stream: false,
                 usage_source: nil, provider_response_id: nil, pricing_mode: nil, metadata: {})
        return unless LlmCostTracker.configuration.enabled

        model = model.to_s.strip.presence || ParsedUsage::UNKNOWN_MODEL
        pricing_mode = pricing_mode.to_s.strip.presence
        pricing_mode = nil if pricing_mode == "standard"
        cost_data = Pricing.cost_for(
          provider: provider,
          model: model,
          token_usage: token_usage,
          pricing_mode: pricing_mode
        )

        UnknownPricing.handle!(model) unless cost_data

        event = build_event(
          provider: provider,
          model: model,
          token_usage: token_usage,
          pricing_mode: pricing_mode,
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

      def build_event(provider:, model:, token_usage:, pricing_mode:, cost_data:, metadata:, latency_ms:, stream:,
                      usage_source:, provider_response_id:)
        usage_source = if usage_source.nil?
                         nil
                       else
                         symbol = usage_source.to_sym
                         USAGE_SOURCES.include?(symbol) ? symbol.to_s : nil
                       end
        tags = metadata.to_h.reject { |key, _value| TRACKING_METADATA_KEYS.include?(key.to_s) }

        Event.new(
          event_id: SecureRandom.uuid,
          provider: provider,
          model: model,
          token_usage: token_usage,
          pricing_mode: pricing_mode,
          cost: cost_data,
          tags: LlmCostTracker::TagSanitizer.call(
            LlmCostTracker::TagContext.tags.merge(tags)
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
