# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "securerandom"

require_relative "ingestion"
require_relative "ledger"
require_relative "pricing"

module LlmCostTracker
  class Tracker
    EVENT_NAME = "llm_request.llm_cost_tracker"

    class << self
      def record(event:, latency_ms: nil, pricing_mode: nil, metadata: {}, context_tags: nil, enforce_budget: false)
        return unless LlmCostTracker.configuration.enabled

        pricing_mode ||= event.pricing_mode
        calculation = Pricing::Calculation.for(
          provider: event.provider, model: event.model, tokens: event.token_usage,
          line_items: resolved_line_items(event), pricing_mode: pricing_mode, usage_source: event.usage_source
        )

        if enforce_budget
          Budget.enforce!(provider: event.provider, model: event.model,
                          estimate: calculation.cost&.total, force: true)
        end

        if calculation.token_cost.nil? && event.token_usage.total_tokens.positive? &&
           calculation.priced_line_items.none?(&:priced?)
          Pricing::Unknown.process(event.model)
        end

        event = build_event(
          event: event,
          calculation: calculation,
          metadata: metadata,
          latency_ms: latency_ms,
          context_tags: context_tags
        )

        if Ingestion.async?
          Ingestion::Inbox.save(event)
          Ingestion::Worker.ensure_started
        else
          Ledger::Store.insert(event)
        end

        yield if block_given?
        notify_subscribers(event)
        Budget.check!(event)

        event
      end

      private

      def resolved_line_items(event)
        Billing::LineItem.from_token_usage(event.token_usage) + event.line_items
      end

      def notify_subscribers(event)
        return unless ActiveSupport::Notifications.notifier.listening?(EVENT_NAME)

        ActiveSupport::Notifications.instrument(EVENT_NAME, event.to_h)
      rescue StandardError => e
        Logging.warn("Subscriber raised on #{EVENT_NAME}: #{e.class}: #{e.message}")
      end

      def build_event(event:, calculation:, metadata:, latency_ms:, context_tags:)
        context_tags = (context_tags || LlmCostTracker::Tags::Context.tags).to_h
        event.with(
          event_id: SecureRandom.uuid,
          pricing_mode: calculation.mode,
          cost: calculation.cost,
          tags: build_tags(context_tags: context_tags, metadata: metadata),
          latency_ms: finite_latency_ms(latency_ms),
          tracked_at: Time.now.utc,
          cost_status: calculation.cost_status,
          pricing_snapshot: calculation.snapshot,
          line_items: calculation.priced_line_items
        )
      end

      def build_tags(context_tags:, metadata:)
        sanitized_metadata = LlmCostTracker::Tags::Sanitizer.call(metadata.to_h)
        LlmCostTracker::Tags::Sanitizer.cap(context_tags.merge(sanitized_metadata)).freeze
      end

      def finite_latency_ms(latency_ms)
        return nil if latency_ms.nil?

        Integer(latency_ms).clamp(0, (1 << 31) - 1)
      rescue ArgumentError, TypeError, FloatDomainError
        nil
      end
    end
  end
end
