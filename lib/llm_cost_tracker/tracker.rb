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
          token_usage: capture.token_usage,
          pricing_mode: pricing_mode
        )

        Pricing::Unknown.handle!(capture.model) unless cost_data

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

      def build_event(capture:, pricing_mode:, cost_data:, pricing_snapshot:, metadata:, latency_ms:, context_tags:)
        tags = metadata.to_h
        context_tags = context_tags.nil? ? LlmCostTracker::Tags::Context.tags : context_tags.to_h
        cost, service_charges = cost_with_service_charges(
          cost_data,
          provider: capture.provider,
          pricing_mode: pricing_mode,
          service_charges: capture.service_charges
        )
        cost_status = Billing::CostStatus.call(
          token_usage: capture.token_usage,
          usage_source: capture.usage_source,
          token_cost: cost_data,
          service_charges: service_charges,
          total_cost: cost&.fetch(:total_cost, nil)
        )

        Event.new(
          event_id: SecureRandom.uuid,
          provider: capture.provider,
          model: capture.model,
          token_usage: capture.token_usage,
          pricing_mode: pricing_mode,
          cost: cost,
          tags: LlmCostTracker::Tags::Sanitizer.call(context_tags.merge(tags)).freeze,
          latency_ms: latency_ms.nil? ? nil : [latency_ms.to_i, 0].max,
          stream: capture.stream ? true : false,
          usage_source: capture.usage_source,
          provider_response_id: capture.provider_response_id.to_s.presence,
          tracked_at: Time.now.utc,
          cost_status: cost_status,
          pricing_snapshot: pricing_snapshot,
          service_charges: service_charges
        )
      end

      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def cost_with_service_charges(cost_data, provider:, pricing_mode:, service_charges:)
        return [cost_data, service_charges] if service_charges.empty?

        service_charges = service_charges.dup if service_charges.any? { |charge| charge.unpriced? && charge.billable? }
        service_total = BigDecimal("0")
        service_charges.each_with_index do |charge, index|
          if charge.unpriced? && charge.billable?
            rate = Pricing.charge_rate(provider: provider, component: charge.component, pricing_mode: pricing_mode)
            if rate
              charge = charge.apply_rate(rate)
              service_charges[index] = charge
            end
          end
          service_total += charge.cost_value
        end
        return [cost_data, service_charges] if service_total.zero? && service_charges.none?(&:priced?)

        cost = cost_data ? cost_data.dup : {}
        total_cost = BigDecimal(cost.fetch(:total_cost, 0).to_s) + service_total
        cost[:total_cost] = total_cost.round(8).to_f
        [cost, service_charges]
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    end
  end
end
