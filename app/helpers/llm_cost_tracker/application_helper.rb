# frozen_string_literal: true

require "json"

module LlmCostTracker
  module ApplicationHelper
    def money(value)
      value = value.to_f
      precision = value.abs < 0.01 && value != 0.0 ? 6 : 2

      "$#{format("%.#{precision}f", value)}"
    end

    def optional_money(value)
      value.nil? ? "n/a" : money(value)
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

    def percent(value)
      "#{format('%.1f', value.to_f)}%"
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

    def dashboard_query(overrides = {})
      request.query_parameters.merge(overrides.stringify_keys)
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
