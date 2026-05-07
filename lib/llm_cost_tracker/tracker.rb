# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "bigdecimal"
require "securerandom"

require_relative "ingestion"
require_relative "ledger"
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
        cost_data, pricing_snapshot = Pricing.cost_and_snapshot_for(
          provider: capture.provider,
          model: capture.model,
          tokens: capture.token_usage,
          pricing_mode: pricing_mode
        )

        Pricing::Unknown.handle!(capture.model) if cost_data.nil? && capture.token_usage.total_tokens.positive?

        event = build_event(
          capture: capture,
          pricing_mode: pricing_mode,
          cost_data: cost_data,
          pricing_snapshot: pricing_snapshot,
          metadata: metadata,
          latency_ms: latency_ms,
          context_tags: context_tags
        )

        ActiveSupport::Notifications.instrument(EVENT_NAME, event.to_h)

        Ingestion::Inbox.save(event)
        Budget.check!(event)

        event
      end

      private

      def token_pricing_partial?(token_usage:, cost_data:)
        return false unless cost_data

        Billing::Components::TOKEN_PRICED.any? do |component|
          token_usage.public_send(component.token_key).positive? && cost_data[component.cost_key].nil?
        end
      end

      # rubocop:disable Metrics/MethodLength
      def build_event(capture:, pricing_mode:, cost_data:, pricing_snapshot:, metadata:, latency_ms:, context_tags:)
        context_tags = (context_tags || LlmCostTracker::Tags::Context.tags).to_h
        line_items, = Pricing.price_line_items(
          provider: capture.provider,
          model: capture.model,
          line_items: capture.line_items,
          pricing_mode: pricing_mode
        )
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
          latency_ms: latency_ms&.to_i&.clamp(0..),
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
      # rubocop:enable Metrics/MethodLength

      def cost_with_service_lines(cost_data, line_items)
        service_lines = line_items.reject(&:token?)
        return cost_data if service_lines.empty?
        return cost_data if service_lines.none?(&:priced?)

        service_total = service_lines.sum(BigDecimal("0"), &:cost_value)
        cost = cost_data ? cost_data.dup : {}
        base_total = BigDecimal(cost.fetch(:total_cost, 0).to_s)
        cost[:total_cost] = (base_total + service_total).round(8).to_f
        cost
      end
    end
  end
end
