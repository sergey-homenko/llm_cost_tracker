# frozen_string_literal: true

require "json"

module LlmCostTracker
  module ApplicationHelper
    TAG_VALUE_SUMMARY_BYTES = 80
    TAG_TOOLTIP_BYTES = 512

    include DashboardFilterOptionsHelper
    include DashboardQueryHelper
    include ChartHelper
    include PaginationHelper
    include TokenUsageHelper
    include InlineStyleHelper

    def dashboard_section
      path = request.path.to_s
      return :models if path.start_with?(models_path)
      return :calls if path.start_with?(calls_path)
      return :tags if path.start_with?(tags_path)
      return :data_quality if path.start_with?(data_quality_path)
      return :pricing if path.start_with?(pricing_path)

      :overview
    end

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

    def format_date(value)
      return "" if value.nil?

      value.strftime("%Y-%m-%d %H:%M")
    end

    def pricing_status(call)
      return "Unknown" if call.total_cost.nil?

      {
        LlmCostTracker::Billing::CostStatus::COMPLETE => "Estimated",
        LlmCostTracker::Billing::CostStatus::FREE => "Free",
        LlmCostTracker::Billing::CostStatus::PARTIAL => "Partial"
      }.fetch(call.cost_status, "Unknown")
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

    def masked_metadata_hash(value)
      return value if value.is_a?(Hash)
      return {} if value.nil?

      JSON.parse(value.to_s)
    rescue JSON::ParserError, TypeError
      {}
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
