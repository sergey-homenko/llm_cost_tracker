# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "active_support/notifications"
require "securerandom"

require_relative "ingestion"
require_relative "ledger"
require_relative "pricing"

module LlmCostTracker
  module Tracker
    EVENT_NAME = "llm_request.llm_cost_tracker"

    class << self
      def record(event:, latency_ms: nil, metadata: {}, context_tags: nil, enforce_budget: false)
        return unless LlmCostTracker.configuration.enabled

        calculation = Pricing::Calculation.for(
          provider: event.provider,
          model: event.model,
          tokens: event.token_usage,
          line_items: event.line_items,
          pricing_mode: event.pricing_mode,
          usage_source: event.usage_source
        )

        tags = build_tags(context_tags: context_tags, metadata: metadata)

        event = build_event(event: event, calculation: calculation, tags: tags, latency_ms: latency_ms)

        if Ingestion.async?
          Ingestion::Inbox.save(event)
          Ingestion::Worker.ensure_started
        else
          Ledger::Store.insert(event)
        end

        yield if block_given?
        notify_subscribers(event)
        behavior_override = :raise if enforce_budget
        begin
          signal_unpriced(event, calculation)
        ensure
          Budget.check!(event, behavior_override: behavior_override)
        end

        event
      end

      def build_tags(context_tags:, metadata:)
        resolved = (context_tags || LlmCostTracker::Tags::Context.tags).to_h
        merged = resolved.merge(LlmCostTracker::Tags::Sanitizer.call(metadata.to_h))
        LlmCostTracker::Tags::Sanitizer.cap(merged.to_a.reverse.uniq { |key, _| key.to_s }.reverse.to_h).freeze
      end

      private

      def signal_unpriced(event, calculation)
        iterations, lines = calculation.priced_line_items.partition { |line| line.kind == "model_iteration" }
        models = iterations.select(&:unpriced?).map { |line| line.details[:model] }
        if calculation.token_cost.nil? && event.token_usage.total_tokens.positive? && lines.none?(&:priced?)
          models.unshift(event.model)
        end
        models.each { |model| Pricing::Unknown.process(model, pricing_mode: calculation.mode) }
      end

      def notify_subscribers(event)
        return unless ActiveSupport::Notifications.notifier.listening?(EVENT_NAME)

        ActiveSupport::Notifications.instrument(EVENT_NAME, event.to_h)
      rescue StandardError => e
        Logging.warn("Subscriber raised on #{EVENT_NAME}: #{e.class}: #{e.message}")
      end

      def build_event(event:, calculation:, tags:, latency_ms:)
        event.with(
          event_id: event.event_id || SecureRandom.uuid,
          pricing_mode: calculation.mode,
          cost: calculation.cost,
          tags: tags,
          latency_ms: finite_latency_ms(latency_ms),
          tracked_at: Time.now.utc,
          cost_status: calculation.cost_status,
          pricing_snapshot: calculation.snapshot,
          line_items: calculation.priced_line_items
        )
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
