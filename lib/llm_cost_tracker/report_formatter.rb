# frozen_string_literal: true

module LlmCostTracker
  class ReportFormatter
    TOP_LIMIT = 5

    def initialize(data)
      @data = data
    end

    def to_s
      lines = ["LLM Cost Report (last #{@data.days} days)", ""]
      append_summary(lines)
      append_cost_section(lines, "By provider", @data.cost_by_provider)
      append_cost_section(lines, "By model", @data.cost_by_model)
      append_cost_section(lines, "By feature", @data.cost_by_feature)
      append_top_calls(lines)
      lines.join("\n")
    end

    private

    def append_summary(lines)
      lines << "Total cost: #{money(@data.total_cost)}"
      lines << "Requests: #{@data.requests_count}"
      lines << "Avg latency: #{average_latency}"
      lines << "Unknown pricing: #{@data.unknown_pricing_count}"
    end

    def append_cost_section(lines, title, rows)
      lines << ""
      lines << "#{title}:"
      return lines << "  none" if rows.empty?

      rows.first(TOP_LIMIT).each do |name, cost|
        lines << "  #{name.to_s.ljust(28)} #{money(cost)}"
      end
    end

    def append_top_calls(lines)
      lines << ""
      lines << "Top expensive calls:"
      return lines << "  none" if @data.top_calls.empty?

      @data.top_calls.first(TOP_LIMIT).each do |call|
        label = "#{call.provider}/#{call.model}"
        lines << "  #{label.ljust(32)} #{money(call.total_cost)}"
      end
    end

    def average_latency
      @data.average_latency_ms ? "#{@data.average_latency_ms.round}ms" : "n/a"
    end

    def money(value)
      "$#{format('%.6f', value.to_f)}"
    end
  end
end
