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

      respond_to do |format|
        format.html do
          @page = Dashboard::Pagination.call(params)
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
      @call = LlmCostTracker::Call.find(params[:id])
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
        "CASE WHEN latency_ms IS NULL THEN 1 ELSE 0 END ASC, latency_ms DESC, #{DEFAULT_ORDER}"
      else
        DEFAULT_ORDER
      end
    end

    def render_csv(relation)
      fields = csv_fields
      CSV.generate do |csv|
        csv << fields.map(&:to_s)

        relation.includes(:tag_records).find_each do |call|
          csv << fields.map { |field| csv_value(field, call) }
        end
      end
    end

    def csv_fields
      %i[tracked_at provider model] +
        TokenUsage.members +
        %i[
          total_cost cost_status pricing_snapshot latency_ms provider_response_id provider_project_id
          provider_api_key_id provider_workspace_id batch tags
        ]
    end

    def csv_value(field, call)
      case field
      when :tracked_at
        call.tracked_at&.utc&.iso8601
      when :provider, :model, :provider_response_id, :provider_project_id, :provider_api_key_id,
           :provider_workspace_id, :cost_status
        csv_safe(call[field])
      when :pricing_snapshot
        csv_safe(csv_json(call.pricing_snapshot))
      when :tags
        csv_safe(call.parsed_tags.to_json)
      else
        call[field]
      end
    end

    def csv_json(value)
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
