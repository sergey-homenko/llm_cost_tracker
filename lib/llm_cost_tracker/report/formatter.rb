# frozen_string_literal: true

module LlmCostTracker
  module Report
    class Formatter
      TOP_LIMIT = 5
      MIN_COLUMN_WIDTH = 28

      def initialize(data, color: $stdout.tty?)
        @data = data
        @color = color
      end

      def to_s
        lines = [bold("LLM Cost Report (last #{@data.days} days)"), ""]
        append_summary(lines)
        append_cost_section(lines, "By provider", @data.cost_by_provider) { |row| row.name.to_s }
        append_cost_section(lines, "By model", @data.cost_by_model) { |row| row.name.to_s }
        append_tag_sections(lines)
        append_top_calls(lines)
        lines.join("\n")
      end

      private

      def append_summary(lines)
        lines << "Total cost: #{money(@data.total_cost)}"
        lines << "Requests: #{@data.requests_count}"
        lines << "Avg latency: #{average_latency}"
        lines << "Unknown pricing: #{colored_unknown_pricing(@data.unknown_pricing_count)}"
      end

      def append_cost_section(lines, title, rows, &name_for)
        lines << ""
        lines << bold("#{title}:")
        return lines << "  none" if rows.empty?

        visible = rows.first(TOP_LIMIT)
        width = column_width(visible, &name_for)
        visible.each do |row|
          lines << "  #{name_for.call(row).ljust(width)} #{money(row.total_cost)}"
        end
      end

      def append_tag_sections(lines)
        @data.cost_by_tags.each do |tag_key, rows|
          append_cost_section(lines, "By tag (#{tag_key})", rows) { |row| row.name.to_s }
        end
      end

      def append_top_calls(lines)
        append_cost_section(lines, "Top expensive calls", @data.top_calls) do |call|
          "#{call.provider}/#{call.model}"
        end
      end

      def column_width(rows, &name_for)
        [MIN_COLUMN_WIDTH, rows.map { |row| name_for.call(row).length }.max.to_i].max
      end

      def average_latency
        @data.average_latency_ms ? "#{@data.average_latency_ms.round}ms" : "n/a"
      end

      def money(value)
        "$#{format('%.6f', value.to_f)}"
      end

      def colored_unknown_pricing(count)
        return count.to_s unless @color

        count.to_i.positive? ? "\e[33m#{count}\e[0m" : "\e[32m#{count}\e[0m"
      end

      def bold(text)
        return text unless @color

        "\e[1m#{text}\e[0m"
      end
    end
  end
end
