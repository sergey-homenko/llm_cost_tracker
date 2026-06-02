# frozen_string_literal: true

require_relative "../pricing"
require_relative "../charges/line_item"
require_relative "../ledger/rollups"
require_relative "../usage/token_usage"

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
          calculation = Pricing::Calculation.for(
            provider: call.provider,
            model: call.model,
            tokens: token_usage_from(call),
            line_items: service_line_items_from(call),
            pricing_mode: call.pricing_mode,
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
          token_priced = calculation.priced_line_items.select(&:token?).index_by { |item| dimension_key(item) }
          service_priced = calculation.priced_line_items.reject(&:token?)
          token_records, service_records = call.line_items.partition { |record| record.unit == "token" }

          token_records.each { |record| apply_rate(record, token_priced[dimension_key(record)]) }
          service_records.sort_by(&:position).zip(service_priced).each { |record, priced| apply_rate(record, priced) }
        end

        def apply_rate(record, priced)
          return unless priced

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

        def dimension_key(item)
          [item.kind, item.direction, item.modality, item.cache_state]
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
          Usage::TokenUsage.build(**call.attributes.transform_keys(&:to_sym).slice(*Usage::TokenUsage.members))
        end

        def service_line_items_from(call)
          call.line_items.reject { |record| record.unit == "token" }.sort_by(&:position).map do |record|
            Charges::LineItem.build(record.attributes.transform_keys(&:to_sym).slice(*Charges::LineItem.members))
          end
        end
      end
    end
  end
end
