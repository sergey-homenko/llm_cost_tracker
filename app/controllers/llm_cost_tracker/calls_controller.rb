# frozen_string_literal: true

require "csv"

module LlmCostTracker
  class CallsController < ApplicationController
    SORT_ORDERS = {
      "expensive"       => "total_cost DESC NULLS LAST, tracked_at DESC",
      "input"           => "input_tokens DESC, tracked_at DESC",
      "output"          => "output_tokens DESC, tracked_at DESC",
      "slow"            => "latency_ms DESC NULLS LAST, tracked_at DESC",
      "unknown_pricing" => "tracked_at DESC, id DESC"
    }.freeze

    CSV_EXPORT_LIMIT = 10_000
    CSV_FORMULA_PREFIXES = ["=", "+", "-", "@", "\t", "\r"].freeze

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
      @tags = @call.parsed_tags
      @metadata_available = @call.has_attribute?("metadata")
      @metadata = @call.read_attribute("metadata") if @metadata_available
      @latency_available = LlmApiCall.latency_column?
    end

    private

    def calls_order(sort)
      SORT_ORDERS[sort] || "tracked_at DESC, id DESC"
    end

    def render_csv(relation)
      latency = LlmApiCall.latency_column?
      CSV.generate do |csv|
        headers = %w[tracked_at provider model input_tokens output_tokens total_tokens total_cost]
        headers << "latency_ms" if latency
        headers << "tags"
        csv << headers

        relation.each do |call|
          row = [
            call.tracked_at&.utc&.iso8601,
            csv_safe(call.provider),
            csv_safe(call.model),
            call.input_tokens,
            call.output_tokens,
            call.total_tokens,
            call.total_cost
          ]
          row << call.latency_ms if latency
          row << csv_safe(call.parsed_tags.to_json)
          csv << row
        end
      end
    end

    def csv_safe(value)
      return value if value.nil?

      string = value.to_s
      CSV_FORMULA_PREFIXES.include?(string[0]) ? "'#{string}" : string
    end
  end
end
