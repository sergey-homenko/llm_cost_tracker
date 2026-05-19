# frozen_string_literal: true

require "csv"
require "json"

module LlmCostTracker
  class CallsController < ApplicationController
    CSV_EXPORT_LIMIT = 10_000
    CSV_EXPORT_BATCH_SIZE = 500
    CSV_FORMULA_PREFIXES = ["=", "+", "-", "@", "\t", "\r"].freeze
    DEFAULT_ORDER = "tracked_at DESC, id DESC"
    SORT_OPTIONS = %w[tracked_at provider model input output cost latency].freeze
    SORT_DIRECTIONS = %w[asc desc].freeze

    def index
      @sort = params[:sort].to_s
      @dir = params[:dir].to_s
      scope = Dashboard::Filter.call(params: params)
      scope = scope.unknown_pricing if params[:cost_status].to_s == "incomplete"
      ordered_scope = scope.order(Arel.sql(calls_order(@sort, @dir)))

      respond_to do |format|
        format.html do
          @page = Dashboard::Pagination.call(params)
          @calls_count, @calls_total_cost = scope.pick(Arel.sql("COUNT(*), COALESCE(SUM(total_cost), 0)"))
          @calls = ordered_scope.includes(:tag_records).limit(@page.limit).offset(@page.offset).to_a
        end
        format.csv do
          response.headers["Cache-Control"] = "no-store"
          send_data render_csv(ordered_scope),
                    type: "text/csv",
                    disposition: %(attachment; filename="llm_calls_#{Time.now.utc.strftime('%Y%m%d_%H%M%S')}.csv")
        end
      end
    end

    def show
      @call = LlmCostTracker::Call.includes(:line_items, :tag_records).find(params[:id])
    end

    private

    def calls_order(sort, dir)
      column = SORT_OPTIONS.include?(sort) ? sort : "tracked_at"
      natural = %w[provider model].include?(column) ? "asc" : "desc"
      direction = (SORT_DIRECTIONS.include?(dir.downcase) ? dir.downcase : natural).upcase

      case column
      when "tracked_at" then "tracked_at #{direction}, id #{direction}"
      when "provider"   then "provider #{direction}, model ASC, #{DEFAULT_ORDER}"
      when "model"      then "model #{direction}, #{DEFAULT_ORDER}"
      when "input"      then "input_tokens #{direction}, #{DEFAULT_ORDER}"
      when "output"     then "output_tokens #{direction}, #{DEFAULT_ORDER}"
      when "cost"       then nulls_last_order("total_cost", direction)
      when "latency"    then nulls_last_order("latency_ms", direction)
      end
    end

    def nulls_last_order(column, direction)
      "CASE WHEN #{column} IS NULL THEN 1 ELSE 0 END ASC, #{column} #{direction}, #{DEFAULT_ORDER}"
    end

    def render_csv(relation)
      fields = csv_fields
      CSV.generate do |csv|
        csv << fields.map(&:to_s)
        each_export_batch(relation) do |call|
          csv << fields.map { |field| csv_value(field, call) }
        end
      end
    end

    def each_export_batch(relation, &)
      offset = 0
      while offset < CSV_EXPORT_LIMIT
        batch_size = [CSV_EXPORT_BATCH_SIZE, CSV_EXPORT_LIMIT - offset].min
        batch = relation.limit(batch_size).offset(offset).preload(:tag_records).to_a
        break if batch.empty?

        batch.each(&)
        offset += batch.size
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
      when :provider_api_key_id, :provider_workspace_id, :provider_project_id
        csv_safe(LlmCostTracker::Masking.mask_value(field, call[field]))
      when :provider, :model, :provider_response_id, :cost_status
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
      Hash(value).deep_stringify_keys.to_json
    end

    def csv_safe(value)
      return value if value.nil?

      string = value.to_s
      stripped = string.lstrip
      CSV_FORMULA_PREFIXES.include?(stripped[0]) ? "'#{string}" : string
    end
  end
end
