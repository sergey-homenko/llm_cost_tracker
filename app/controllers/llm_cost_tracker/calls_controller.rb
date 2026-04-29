# frozen_string_literal: true

require "csv"
require "json"

module LlmCostTracker
  class CallsController < ApplicationController
    CSV_EXPORT_LIMIT = 10_000
    CSV_FORMULA_PREFIXES = ["=", "+", "-", "@", "\t", "\r"].freeze
    DEFAULT_ORDER = "tracked_at DESC, id DESC"

    def index
      @sort = params[:sort].to_s
      scope = Dashboard::Filter.call(params: params)
      scope = scope.unknown_pricing if @sort == "unknown_pricing"
      ordered_scope = scope.order(Arel.sql(calls_order(@sort)))
      @latency_available = LlmApiCall.latency_column?

      respond_to do |format|
        format.html do
          @page = Pagination.call(params)
          @calls_count = scope.count
          @calls = ordered_scope.limit(@page.limit).offset(@page.offset).to_a
        end
        format.csv do
          send_data render_csv(ordered_scope.limit(CSV_EXPORT_LIMIT)),
                    type: "text/csv",
                    disposition: %(attachment; filename="llm_calls_#{Time.now.utc.strftime('%Y%m%d_%H%M%S')}.csv")
        end
      end
    end

    def show
      @call = LlmApiCall.find(params[:id])
      @latency_available = LlmApiCall.latency_column?
    end

    private

    def calls_order(sort)
      case sort
      when "expensive"
        "CASE WHEN total_cost IS NULL THEN 1 ELSE 0 END ASC, total_cost DESC, #{DEFAULT_ORDER}"
      when "input"
        "input_tokens DESC, #{DEFAULT_ORDER}"
      when "output"
        "output_tokens DESC, #{DEFAULT_ORDER}"
      when "slow"
        return DEFAULT_ORDER unless LlmApiCall.latency_column?

        "CASE WHEN latency_ms IS NULL THEN 1 ELSE 0 END ASC, latency_ms DESC, #{DEFAULT_ORDER}"
      else
        DEFAULT_ORDER
      end
    end

    def render_csv(relation)
      latency = LlmApiCall.latency_column?
      provider_response_id = LlmApiCall.provider_response_id_column?
      columns = %i[tracked_at provider model input_tokens output_tokens total_tokens total_cost]
      columns << :latency_ms if latency
      columns << :provider_response_id if provider_response_id
      columns << :tags
      CSV.generate do |csv|
        headers = %w[tracked_at provider model input_tokens output_tokens total_tokens total_cost]
        headers << "latency_ms" if latency
        headers << "provider_response_id" if provider_response_id
        headers << "tags"
        csv << headers

        relation.pluck(*columns).each do |values|
          row_data = columns.zip(values).to_h
          row = [
            row_data[:tracked_at]&.utc&.iso8601,
            csv_safe(row_data[:provider]),
            csv_safe(row_data[:model]),
            row_data[:input_tokens],
            row_data[:output_tokens],
            row_data[:total_tokens],
            row_data[:total_cost]
          ]
          row << row_data[:latency_ms] if latency
          row << csv_safe(row_data[:provider_response_id]) if provider_response_id
          row << csv_safe(csv_tags(row_data[:tags]))
          csv << row
        end
      end
    end

    def csv_tags(value)
      return value.transform_keys(&:to_s).to_json if value.is_a?(Hash)

      JSON.parse(value || "{}").to_json
    rescue JSON::ParserError
      "{}"
    end

    def csv_safe(value)
      return value if value.nil?

      string = value.to_s
      stripped = string.lstrip
      CSV_FORMULA_PREFIXES.include?(stripped[0]) ? "'#{string}" : string
    end
  end
end
