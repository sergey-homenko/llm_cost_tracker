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

      def record(capture:, latency_ms: nil, pricing_mode: nil, metadata: {})
        return unless LlmCostTracker.configuration.enabled

        pricing_mode = pricing_mode.to_s.strip.presence
        pricing_mode = nil if pricing_mode == "standard"
        cost_data = Pricing.cost_for(
          provider: capture.provider,
          model: capture.model,
          token_usage: capture.token_usage,
          pricing_mode: pricing_mode
        )

        UnknownPricing.handle!(capture.model) unless cost_data

        event = build_event(
          capture: capture,
          pricing_mode: pricing_mode,
          cost_data: cost_data,
          metadata: metadata,
          latency_ms: latency_ms
        )

        ActiveSupport::Notifications.instrument(EVENT_NAME, event.to_h)

        Ledger.save(event)
        Budget.check!(event)

        event
      end

      private

      def build_event(capture:, pricing_mode:, cost_data:, metadata:, latency_ms:)
        usage_source = if capture.usage_source.nil?
                         nil
                       else
                         symbol = capture.usage_source.to_sym
                         USAGE_SOURCES.include?(symbol) ? symbol.to_s : nil
                       end
        tags = metadata.to_h.reject { |key, _value| TRACKING_METADATA_KEYS.include?(key.to_s) }

        Event.new(
          event_id: SecureRandom.uuid,
          provider: capture.provider,
          model: capture.model,
          token_usage: capture.token_usage,
          pricing_mode: pricing_mode,
          cost: cost_data,
          tags: LlmCostTracker::TagSanitizer.call(
            LlmCostTracker::TagContext.tags.merge(tags)
          ).freeze,
          latency_ms: latency_ms.nil? ? nil : [latency_ms.to_i, 0].max,
          stream: capture.stream ? true : false,
          usage_source: usage_source,
          provider_response_id: capture.provider_response_id.to_s.presence,
          tracked_at: Time.now.utc
        )
      end
    end
  end
end
