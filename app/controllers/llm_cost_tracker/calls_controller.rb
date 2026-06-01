# frozen_string_literal: true

require "csv"
require "json"

module LlmCostTracker
  class CallsController < ApplicationController
    CSV_EXPORT_LIMIT = 10_000
    CSV_EXPORT_BATCH_SIZE = 500
    CSV_FORMULA_PREFIXES = ["=", "+", "-", "@", "\t", "\r"].freeze
    DEFAULT_TIEBREAKER = { tracked_at: :desc, id: :desc }.freeze
    SORT_OPTIONS = %w[tracked_at provider model input output cost latency].freeze
    NULLS_LAST_GUARD = {
      total_cost: Arel.sql("CASE WHEN total_cost IS NULL THEN 1 ELSE 0 END ASC"),
      latency_ms: Arel.sql("CASE WHEN latency_ms IS NULL THEN 1 ELSE 0 END ASC")
    }.freeze

    def index
      @sort = params[:sort].to_s
      @dir = params[:dir].to_s
      scope = Dashboard::Filter.call(params: params)
      scope = scope.unknown_pricing if params[:cost_status].to_s == "incomplete"
      ordered_scope = scope.order(*calls_order(@sort, @dir))

      respond_to do |format|
        format.html do
          @page = Dashboard::Pagination.call(params)
          @calls_count, @calls_total_cost = scope.pick(Arel.sql("COUNT(*), COALESCE(SUM(total_cost), 0)"))
          @calls = ordered_scope.includes(:tag_records).limit(@page.per).offset(@page.offset).to_a
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
      column = SORT_OPTIONS.include?(sort) ? sort.to_sym : :tracked_at
      natural = %i[provider model].include?(column) ? :asc : :desc
      direction = Dashboard::Sort::DIRECTIONS.include?(dir.downcase) ? dir.downcase.to_sym : natural

      case column
      when :tracked_at then [{ tracked_at: direction, id: direction }]
      when :provider   then [{ provider: direction, model: :asc, **DEFAULT_TIEBREAKER }]
      when :model      then [{ model: direction, **DEFAULT_TIEBREAKER }]
      when :input      then [{ input_tokens: direction, **DEFAULT_TIEBREAKER }]
      when :output     then [{ output_tokens: direction, **DEFAULT_TIEBREAKER }]
      when :cost       then [NULLS_LAST_GUARD[:total_cost], { total_cost: direction, **DEFAULT_TIEBREAKER }]
      when :latency    then [NULLS_LAST_GUARD[:latency_ms], { latency_ms: direction, **DEFAULT_TIEBREAKER }]
      end
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
        Usage::TokenUsage.members +
        %i[
          total_cost cost_status pricing_snapshot latency_ms provider_response_id provider_project_id
          provider_api_key_id provider_workspace_id batch tags
        ]
    end

    def csv_value(field, call)
      case field
      when :tracked_at
        call.tracked_at.utc.iso8601
      when :provider_api_key_id, :provider_workspace_id, :provider_project_id
        csv_safe(LlmCostTracker::Masking.mask_value(field, call[field]))
      when :provider, :model, :provider_response_id, :cost_status
        csv_safe(call[field])
      when :pricing_snapshot
        csv_safe(csv_json(call.pricing_snapshot))
      when :tags
        csv_safe(call.tag_pairs.to_json)
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
