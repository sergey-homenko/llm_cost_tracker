# frozen_string_literal: true

require_relative "../pricing"
require_relative "../billing/line_item"
require_relative "../ledger/rollups"
require_relative "../token_usage"

module LlmCostTracker
  module Pricing
    class Backfill
      Result = Data.define(:examined, :recomputed, :still_unknown)
      RollupEvent = Data.define(:provider, :tracked_at, :pricing_snapshot, :total_cost)

      DEFAULT_BATCH_SIZE = 500

      class << self
        def call(scope: default_scope, batch_size: DEFAULT_BATCH_SIZE)
          examined = 0
          recomputed = 0

          scope.includes(:line_items).find_in_batches(batch_size: batch_size) do |batch|
            rollup_events = []
            LlmCostTracker::Call.transaction do
              batch.each do |call|
                examined += 1
                calculation = recompute_for(call)
                next unless calculation

                persist!(call, calculation)
                rollup_events << rollup_event_for(call, calculation)
                recomputed += 1
              end
              Ledger::Rollups.increment!(rollup_events) if rollup_events.any?
            end
          end

          Result.new(examined: examined, recomputed: recomputed, still_unknown: examined - recomputed)
        end

        def default_scope
          LlmCostTracker::Call.where(total_cost: nil)
        end

        private

        def recompute_for(call)
          calculation = Pricing.assess(
            provider: call.provider, model: call.model, tokens: token_usage_from(call),
            line_items: billing_line_items_from(call), pricing_mode: call.pricing_mode,
            usage_source: call.usage_source
          )
          calculation if calculation.token_cost
        end

        def persist!(call, calculation)
          call.update!(
            total_cost: calculation.cost.total,
            pricing_snapshot: calculation.snapshot,
            cost_status: calculation.cost_status
          )
          call.line_items.to_a.zip(calculation.priced_line_items).each do |record, priced|
            next if priced.nil?

            record.update!(
              rate_amount: priced.rate_amount,
              rate_quantity: priced.rate_quantity,
              cost: priced.cost,
              currency: priced.currency,
              cost_status: priced.cost_status,
              price_key: priced.price_key,
              price_source: priced.price_source,
              price_source_version: priced.price_source_version
            )
          end
        end

        def rollup_event_for(call, calculation)
          RollupEvent.new(
            provider: call.provider,
            tracked_at: call.tracked_at,
            pricing_snapshot: calculation.snapshot,
            total_cost: calculation.cost.total
          )
        end

        def token_usage_from(call)
          TokenUsage.build(
            input_tokens: call.input_tokens,
            output_tokens: call.output_tokens,
            cache_read_input_tokens: call.cache_read_input_tokens,
            cache_write_input_tokens: call.cache_write_input_tokens,
            cache_write_extended_input_tokens: call.cache_write_extended_input_tokens,
            audio_input_tokens: call.audio_input_tokens,
            audio_output_tokens: call.audio_output_tokens,
            image_input_tokens: call.image_input_tokens,
            image_output_tokens: call.image_output_tokens,
            hidden_output_tokens: call.hidden_output_tokens,
            total_tokens: call.total_tokens
          )
        end

        def billing_line_items_from(call)
          call.line_items.map do |record|
            Billing::LineItem.build(
              kind: record.kind, direction: record.direction, modality: record.modality,
              cache_state: record.cache_state, quantity: record.quantity, unit: record.unit,
              rate_amount: record.rate_amount, rate_quantity: record.rate_quantity,
              cost: record.cost, currency: record.currency, cost_status: record.cost_status,
              pricing_basis: record.pricing_basis, price_key: record.price_key,
              price_source: record.price_source, price_source_version: record.price_source_version,
              provider_field: record.provider_field, provider_item_id: record.provider_item_id,
              details: record.details
            )
          end
        end
      end
    end
  end
end
