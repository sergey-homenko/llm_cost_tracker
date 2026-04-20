# frozen_string_literal: true

require "json"

module LlmCostTracker
  module ApplicationHelper
    def coverage_percent(numerator, denominator)
      return 0.0 unless denominator.to_i.positive?

      (numerator.to_f / denominator) * 100.0
    end

    def money(value)
      value = value.to_f
      precision = value.abs < 0.01 && value != 0.0 ? 6 : 2

      "$#{format("%.#{precision}f", value)}"
    end

    def optional_money(value)
      value.nil? ? "n/a" : money(value)
    end

    def optional_number(value)
      value.nil? ? "n/a" : number(value)
    end

    def number(value)
      number_with_delimiter(value.to_i)
    end

    def format_tokens(value)
      number(value)
    end

    def format_date(value)
      value.respond_to?(:strftime) ? value.strftime("%Y-%m-%d %H:%M") : value.to_s
    end

    def pricing_status(call)
      call.total_cost.nil? ? "Unknown pricing" : "Estimated"
    end

    def percent(value)
      "#{format('%.1f', value.to_f)}%"
    end

    def delta_badge(delta_percent, mode: :cost)
      return { text: "vs. prior: n/a", css_class: "lct-delta lct-delta-neutral" } if delta_percent.nil?

      rounded = delta_percent.round(1)
      return { text: "= vs. prior", css_class: "lct-delta lct-delta-neutral" } if rounded.zero?

      sign = rounded.positive? ? "+" : ""
      text = "#{sign}#{format('%.1f', rounded)}% vs. prior"
      css_class = if mode == :neutral
                    "lct-delta lct-delta-neutral"
                  elsif rounded.positive?
                    "lct-delta lct-delta-up"
                  else
                    "lct-delta lct-delta-down"
                  end

      { text: text, css_class: css_class }
    end

    def bar_width(value, max)
      max = max.to_f
      return "0%" unless max.positive?

      "#{[(value.to_f / max) * 100.0, 100.0].min.round(2)}%"
    end

    def safe_json(value)
      parsed = value.is_a?(String) ? JSON.parse(value) : value
      JSON.pretty_generate(parsed || {})
    rescue JSON::ParserError, TypeError
      value.to_s
    end

    def tags_summary(tags, limit: 3)
      tags = normalized_tags(tags)
      return "(untagged)" if tags.empty?

      summary = tags.first(limit).map { |key, value| "#{key}=#{tag_value_summary(value)}" }
      summary << "+#{tags.size - limit}" if tags.size > limit
      summary.join(", ")
    end

    def current_query(overrides = {})
      request.query_parameters.symbolize_keys.merge(overrides)
    end

    private

    def normalized_tags(tags)
      return tags.transform_keys(&:to_s) if tags.is_a?(Hash)

      JSON.parse(tags || "{}")
    rescue JSON::ParserError, TypeError
      {}
    end

    def tag_value_summary(value)
      case value
      when Hash, Array
        JSON.generate(value)
      else
        value.to_s
      end
    end
  end
end
