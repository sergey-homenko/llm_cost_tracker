# frozen_string_literal: true

require "bigdecimal"

require_relative "check"
require_relative "probe"

module LlmCostTracker
  class Doctor
    class PricingSnapshotDriftCheck
      SAMPLE_SIZE = 200
      EPSILON = BigDecimal("0.00000001")

      def call
        return unless Probe.table_exists?("llm_cost_tracker_calls")
        return unless Probe.table_exists?("llm_cost_tracker_call_line_items")

        sampled_ids = LlmCostTracker::Call
                      .where.not(pricing_snapshot: nil)
                      .where(cost_status: %w[complete free])
                      .order(id: :desc)
                      .limit(SAMPLE_SIZE)
                      .pluck(:id)
        return Check.new(:ok, "pricing snapshot drift", "no snapshotted calls to inspect") if sampled_ids.empty?

        calls_by_id = LlmCostTracker::Call.where(id: sampled_ids).index_by(&:id)
        line_items_by_call = LlmCostTracker::CallLineItem
                             .where(llm_cost_tracker_call_id: sampled_ids, unit: "token")
                             .group_by(&:llm_cost_tracker_call_id)

        drifted = sampled_ids.flat_map do |id|
          call = calls_by_id[id]
          rates = rates_for(call.pricing_snapshot)
          next [] if rates.nil? || rates.empty?

          (line_items_by_call[id] || []).filter_map { |item| drift_message_for(item, rates, call_id: id) }
        end

        return ok_check(sampled_ids.size) if drifted.empty?

        Check.new(
          :warn,
          "pricing snapshot drift",
          "line item cost diverges from pricing_snapshot rate in #{drifted.size} cases across " \
          "#{sampled_ids.size} sampled calls: #{drifted.first(5).join('; ')}#{'; ...' if drifted.size > 5}"
        )
      end

      private

      def ok_check(sample_size)
        Check.new(:ok, "pricing snapshot drift",
                  "line item costs match pricing_snapshot rates in #{sample_size} sampled calls")
      end

      def rates_for(snapshot)
        rates = snapshot.is_a?(Hash) ? (snapshot["rates"] || snapshot[:rates]) : nil
        rates.is_a?(Hash) ? rates : nil
      end

      def drift_message_for(line_item, rates, call_id:)
        return nil unless line_item.price_key

        rate = rates[line_item.price_key.to_s] || rates[line_item.price_key.to_sym]
        return nil unless rate.is_a?(Hash)

        rate_amount = decimal(rate["amount"] || rate[:amount])
        rate_quantity = decimal(rate["quantity"] || rate[:quantity])
        return nil if rate_amount.nil? || rate_quantity.nil? || rate_quantity.zero?

        expected = (decimal(line_item.quantity) * rate_amount) / rate_quantity
        actual = decimal(line_item.cost) || BigDecimal("0")
        return nil if (expected - actual).abs <= EPSILON

        "##{call_id}.#{line_item.price_key}: expected=#{expected.round(8).to_s('F')} stored=#{actual.to_s('F')}"
      end

      def decimal(value)
        return nil if value.nil?

        BigDecimal(value.to_s)
      end
    end
  end
end
