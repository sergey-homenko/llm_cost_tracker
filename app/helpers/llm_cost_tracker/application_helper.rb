# frozen_string_literal: true

require "json"

module LlmCostTracker
  module ApplicationHelper
    TAG_VALUE_SUMMARY_BYTES = 80
    TAG_TOOLTIP_BYTES = 512
    SENSITIVE_ATTRIBUTION_KEYS = %i[provider_api_key_id provider_workspace_id provider_organization_id].to_set.freeze
    MASK_TAIL_LENGTH = 4

    include DashboardFilterHelper
    include DashboardFilterOptionsHelper
    include DashboardQueryHelper
    include ChartHelper
    include PaginationHelper
    include TokenUsageHelper

    def coverage_percent(numerator, denominator)
      denominator = denominator.to_f
      return 0.0 unless denominator.positive?

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

    def format_date(value)
      value.try(:strftime, "%Y-%m-%d %H:%M") || value.to_s
    end

    def pricing_status(call)
      return "Unknown pricing" if call.total_cost.nil?
      return "Estimated" unless call.has_attribute?(:cost_status)

      {
        LlmCostTracker::Billing::CostStatus::COMPLETE => "Estimated",
        LlmCostTracker::Billing::CostStatus::FREE => "Free",
        LlmCostTracker::Billing::CostStatus::PARTIAL => "Partial pricing"
      }.fetch(call.cost_status, "Unknown pricing")
    end

    def percent(value)
      "#{format('%.1f', value.to_f)}%"
    end

    def delta_badge(delta_percent, mode: :cost)
      return { text: "n/a vs. prior", css_class: "lct-delta-badge lct-delta-neutral" } if delta_percent.nil?

      rounded = delta_percent.round(1)
      return { text: "0.0% vs. prior", css_class: "lct-delta-badge lct-delta-neutral" } if rounded.zero?

      sign = rounded.positive? ? "+" : ""
      text = "#{sign}#{format('%.1f', rounded)}% vs. prior"
      css_class = if mode == :neutral
                    "lct-delta-badge lct-delta-neutral"
                  elsif rounded.positive?
                    "lct-delta-badge lct-delta-up"
                  else
                    "lct-delta-badge lct-delta-down"
                  end

      { text: text, css_class: css_class }
    end

    def bar_width(value, max)
      max = max.to_f
      return "0%" unless max.positive?

      "#{[(value.to_f / max) * 100.0, 100.0].min.round(2)}%"
    end

    def stack_segments(entries)
      total = entries.sum { |entry| entry[:value].to_f }
      return [] unless total.positive?

      entries.filter_map do |entry|
        value = entry[:value].to_f
        next unless value.positive?

        entry.merge(percent: (value / total) * 100.0)
      end
    end

    def safe_json(value)
      parsed = value.is_a?(String) ? JSON.parse(value) : value
      JSON.pretty_generate(parsed || {})
    rescue JSON::ParserError, TypeError
      value.to_s
    end

    def tag_chip_entries(tags, limit: 3)
      normalized = normalized_tags(tags)
      return [] if normalized.empty?

      visible = normalized.first(limit).map do |key, value|
        { key: key.to_s, value: tag_value_summary(value) }
      end
      visible << { more: normalized.size - limit } if normalized.size > limit
      visible
    end

    def tag_chips_title(tags)
      truncate_text(safe_json(tags), TAG_TOOLTIP_BYTES)
    end

    def current_query(overrides = {})
      request.query_parameters.symbolize_keys.merge(overrides)
    end

    def calls_query_for_model(provider:, model:)
      current_query(provider: provider, model: model, page: nil, per: nil, format: nil)
    end

    def attribution_summary(attribution)
      attribution.map do |key, value|
        masked = SENSITIVE_ATTRIBUTION_KEYS.include?(key.to_sym) ? mask_secret(value) : value
        "#{key}=#{masked}"
      end.join(", ")
    end

    def mask_secret(value)
      string = value.to_s
      return string if string.length <= MASK_TAIL_LENGTH

      "***#{string[-MASK_TAIL_LENGTH, MASK_TAIL_LENGTH]}"
    end

    private

    def normalized_tags(tags)
      return tags.transform_keys(&:to_s) if tags.is_a?(Hash)

      JSON.parse(tags || "{}")
    rescue JSON::ParserError, TypeError
      {}
    end

    def tag_value_summary(value)
      string = case value
               when Hash, Array
                 JSON.generate(value)
               else
                 value.to_s
               end

      truncate_text(string, TAG_VALUE_SUMMARY_BYTES)
    end

    def truncate_text(string, limit)
      return string if string.bytesize <= limit

      "#{string.byteslice(0, limit).encode('UTF-8', invalid: :replace, undef: :replace)}..."
    end
  end
end
