# frozen_string_literal: true

module LlmCostTracker
  class CallsController < ApplicationController
    CSV_EXPORT_LIMIT = 10_000
    CSV_EXPORT_BATCH_SIZE = 500

    def index
      scope = Dashboard::Filter.call(params: params)
      scope = scope.unknown_pricing if params[:cost_status].to_s == "incomplete"
      ordered_scope = Dashboard::CallOrder.call(scope, sort: params[:sort], direction: params[:dir])

      respond_to do |format|
        format.html { assign_page(scope, ordered_scope) }
        format.csv { send_csv(ordered_scope) }
      end
    end

    def show
      @call = LlmCostTracker::Call.includes(:line_items, :tag_records).find(params[:id])
    end

    private

    def assign_page(scope, ordered_scope)
      @page = Dashboard::Pagination.call(params)
      @calls_count, @calls_total_cost = scope.pick(Arel.sql("COUNT(*), COALESCE(SUM(total_cost), 0)"))
      @calls = ordered_scope.includes(:tag_records).limit(@page.per).offset(@page.offset).to_a
    end

    def send_csv(relation)
      response.headers["Cache-Control"] = "no-store"
      send_data Dashboard::CallsExport.call(relation, limit: CSV_EXPORT_LIMIT, batch_size: CSV_EXPORT_BATCH_SIZE),
                type: "text/csv",
                disposition: %(attachment; filename="llm_calls_#{Time.now.utc.strftime('%Y%m%d_%H%M%S')}.csv")
    end
  end
end
