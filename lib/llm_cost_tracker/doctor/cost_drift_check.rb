# frozen_string_literal: true

require "bigdecimal"

require_relative "check"
require_relative "probe"

module LlmCostTracker
  class Doctor
    class CostDriftCheck
      SAMPLE_SIZE = 200
      EPSILON = BigDecimal("0.00000001")

      def call
        return unless Probe.table_exists?("llm_cost_tracker_calls")
        return unless Probe.table_exists?("llm_cost_tracker_call_line_items")

        sampled = LlmCostTracker::Call
                  .where.not(total_cost: nil)
                  .where(cost_status: %w[complete free partial])
                  .order(id: :desc)
                  .limit(SAMPLE_SIZE)
                  .pluck(:id, :total_cost, :cost_status)
        return Check.new(:ok, "cost drift", "no priced calls to inspect") if sampled.empty?

        line_item_totals = LlmCostTracker::CallLineItem
                           .where(llm_cost_tracker_call_id: sampled.map(&:first))
                           .group(:llm_cost_tracker_call_id)
                           .sum(:cost)

        drifted = sampled.filter_map do |id, total_cost, cost_status|
          line_total = line_item_totals[id] || BigDecimal("0")
          header = BigDecimal(total_cost.to_s)
          next if cost_status == "partial" && header >= line_total
          next if (header - line_total).abs <= EPSILON

          "##{id}: header=#{header.to_s('F')} line_items=#{line_total.to_s('F')}"
        end

        if drifted.empty?
          return Check.new(:ok, "cost drift",
                           "header total_cost matches line items in #{sampled.size} sampled calls")
        end

        Check.new(
          :warn,
          "cost drift",
          "header total_cost diverges from line items in #{drifted.size}/#{sampled.size} sampled calls: " \
          "#{drifted.first(5).join('; ')}#{'; …' if drifted.size > 5}"
        )
      end
    end
  end
end
