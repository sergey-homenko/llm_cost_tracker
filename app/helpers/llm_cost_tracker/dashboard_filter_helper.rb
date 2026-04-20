# frozen_string_literal: true

module LlmCostTracker
  module DashboardFilterHelper
    CALLS_SORT_LABELS = {
      "expensive" => "Most expensive",
      "input" => "Largest input",
      "output" => "Largest output",
      "slow" => "Slowest",
      "unknown_pricing" => "Unknown pricing only"
    }.freeze

    MODELS_SORT_LABELS = {
      "calls" => "Call volume",
      "avg_cost" => "Avg cost / call",
      "latency" => "Avg latency"
    }.freeze

    def dashboard_active_filters(include_sort: false, sort: nil, sort_label: nil)
      chips = []
      chips << date_chip if params[:from].present? || params[:to].present?
      chips.concat(scope_chips)
      chips.concat(tag_filter_chips)
      chips << sort_chip(sort, sort_label) if include_sort && (sort.present? || sort_label.present?)
      chips
    end

    def dashboard_date_range_label(from, to)
      from_label = short_date_label(from) || "Any time"
      to_label = short_date_label(to) || "Now"
      "#{from_label} - #{to_label}"
    end

    def dashboard_sort_label(sort)
      CALLS_SORT_LABELS[sort.to_s] || "Recent first"
    end

    def models_sort_label(sort)
      MODELS_SORT_LABELS[sort.to_s] || "Total spend"
    end

    private

    def date_chip
      {
        label: "Date",
        value: dashboard_date_range_label(params[:from], params[:to]),
        path: dashboard_filter_path(current_query(from: nil, to: nil, page: nil))
      }
    end

    def scope_chips
      %i[provider model].filter_map do |key|
        value = params[key]
        next if value.blank?

        {
          label: key.to_s.humanize,
          value: value,
          path: dashboard_filter_path(current_query(key => nil, page: nil))
        }
      end
    end

    def sort_chip(sort, sort_label)
      {
        label: "Sort",
        value: sort_label || dashboard_sort_label(sort),
        path: dashboard_filter_path(current_query(sort: nil, page: nil))
      }
    end

    def short_date_label(value)
      return nil if value.blank?

      Date.iso8601(value.to_s).strftime("%b %-d, %Y")
    rescue ArgumentError
      value.to_s
    end

    def tag_filter_chips
      tag_params = normalized_query_tags(params[:tag])
      stored_tag_chips(tag_params)
    end

    def stored_tag_chips(tag_params)
      return [] unless tag_params.is_a?(Hash)

      tag_params.filter_map do |key, value|
        next if key.blank? || value.blank?

        {
          label: "Tag",
          value: "#{key}=#{value}",
          path: dashboard_filter_path(current_query(tag: tag_params.except(key.to_s).presence, page: nil))
        }
      end
    end
  end
end
