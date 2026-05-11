# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "bigdecimal"
require "securerandom"

require_relative "ingestion"
require_relative "ledger"
require_relative "logging"
require_relative "pricing"
require_relative "billing/cost_status"

module LlmCostTracker
  class Tracker
    EVENT_NAME = "llm_request.llm_cost_tracker"

    class << self
      def enforce_budget!
        return unless LlmCostTracker.configuration.enabled

        Budget.enforce!
      end

      def record(capture:, latency_ms: nil, pricing_mode: nil, metadata: {}, context_tags: nil)
        return unless LlmCostTracker.configuration.enabled

        pricing_mode = Pricing.normalize_mode(pricing_mode) || capture.pricing_mode
        cost_data, pricing_snapshot, priced_line_items = Pricing.calculate(
          provider: capture.provider,
          model: capture.model,
          tokens: capture.token_usage,
          line_items: capture.line_items,
          pricing_mode: pricing_mode
        )

        Pricing::Unknown.handle!(capture.model) if cost_data.nil? && capture.token_usage.total_tokens.positive?

        event = build_event(
          capture: capture,
          pricing_mode: pricing_mode,
          cost_data: cost_data,
          pricing_snapshot: pricing_snapshot,
          line_items: priced_line_items,
          metadata: metadata,
          latency_ms: latency_ms,
          context_tags: context_tags
        )

        save_event(event)
        notify_subscribers(event)
        Budget.check!(event)

        event
      end

      def save_event(event)
        if LlmCostTracker.configuration.durable_ingestion
          Ingestion::Inbox.save(event)
        else
          Ingestion::Inline.save(event)
        end
      end

      def notify_subscribers(event)
        return unless ActiveSupport::Notifications.notifier.listening?(EVENT_NAME)

        ActiveSupport::Notifications.instrument(EVENT_NAME, event.to_h)
      rescue StandardError => e
        Logging.warn("Subscriber raised on #{EVENT_NAME}: #{e.class}: #{e.message}")
      end

      private

      def token_pricing_partial?(token_usage:, cost_data:)
        return false unless cost_data

        Billing::Components::TOKEN_PRICED.any? do |component|
          token_usage.public_send(component.token_key).positive? && cost_data[component.cost_key].nil?
        end
      end

      def build_event(capture:, pricing_mode:, cost_data:, pricing_snapshot:, line_items:,
                      metadata:, latency_ms:, context_tags:)
        context_tags = (context_tags || LlmCostTracker::Tags::Context.tags).to_h
        cost = cost_with_service_lines(cost_data, line_items)
        cost_status = Billing::CostStatus.call(
          token_usage: capture.token_usage,
          usage_source: capture.usage_source,
          token_cost: cost_data,
          token_pricing_partial: token_pricing_partial?(token_usage: capture.token_usage, cost_data: cost_data),
          service_line_items: line_items.reject(&:token?),
          total_cost: cost&.fetch(:total_cost, nil)
        )

        Event.new(
          event_id: SecureRandom.uuid,
          provider: capture.provider,
          model: capture.model,
          token_usage: capture.token_usage,
          pricing_mode: pricing_mode,
          cost: cost,
          tags: LlmCostTracker::Tags::Sanitizer.call(context_tags.merge(metadata.to_h)).freeze,
          latency_ms: finite_latency_ms(latency_ms),
          stream: capture.stream,
          usage_source: capture.usage_source,
          provider_response_id: capture.provider_response_id,
          provider_project_id: capture.provider_project_id,
          provider_api_key_id: capture.provider_api_key_id,
          provider_workspace_id: capture.provider_workspace_id,
          batch: capture.batch,
          tracked_at: Time.now.utc,
          cost_status: cost_status,
          pricing_snapshot: pricing_snapshot,
          line_items: line_items
        )
      end

      def finite_latency_ms(latency_ms)
        return nil if latency_ms.nil?

        Integer(latency_ms).clamp(0, (1 << 31) - 1)
      rescue ArgumentError, TypeError, FloatDomainError
        nil
      end

      def cost_with_service_lines(cost_data, line_items)
        priced_services = line_items.reject(&:token?).select(&:priced?)
        return cost_data if priced_services.empty?

        base_currency = (cost_data && cost_data[:currency]) || Billing::LineItem::USD
        matching, mismatched = priced_services.partition { |line| line.currency.to_s == base_currency.to_s }
        warn_currency_mismatch(mismatched, base_currency) if mismatched.any?

        cost = cost_data ? cost_data.dup : {}
        cost[:currency] ||= base_currency.to_s
        return cost if matching.empty?

        service_total = matching.sum(BigDecimal("0"), &:cost_value)
        base_total = BigDecimal(cost.fetch(:total_cost, 0).to_s)
        cost[:total_cost] = (base_total + service_total).round(8)
        cost
      end

      def warn_currency_mismatch(lines, base_currency)
        currencies = lines.map { |line| line.currency.to_s }.uniq.sort
        Logging.warn(
          "Service line currency mismatch: header is #{base_currency}, dropping " \
          "#{lines.size} priced line(s) in #{currencies.join(', ')} from header total. " \
          "Per-line costs are still recorded; header total reflects #{base_currency} only."
        )
      end
    end
  end
end
