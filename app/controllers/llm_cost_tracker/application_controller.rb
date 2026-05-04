# frozen_string_literal: true

module LlmCostTracker
  class ApplicationController < ActionController::Base
    layout "llm_cost_tracker/application"

    before_action :ensure_current_schema

    rescue_from ActiveRecord::ConnectionNotEstablished, with: :render_database_error
    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
    rescue_from ActiveRecord::StatementInvalid, with: :render_database_error
    rescue_from LlmCostTracker::InvalidFilterError, with: :render_invalid_filter

    private

    def ensure_current_schema
      unless LlmCostTracker::Call.table_exists?
        @setup_message = "The llm_cost_tracker_calls table is not available yet."
        return render template: "llm_cost_tracker/shared/setup_required"
      end

      schema_errors = LlmCostTracker::Ledger::Schema::Calls.current_schema_errors
      if schema_errors.any?
        @setup_message = "The llm_cost_tracker_calls table does not match the current LLM Cost Tracker schema."
        @setup_details = schema_errors
        render template: "llm_cost_tracker/shared/setup_required"
        return
      end

      period_total_errors = LlmCostTracker::Ledger::Schema::PeriodTotals.current_schema_errors
      if period_total_errors.any?
        @setup_message = "The llm_cost_tracker_period_totals table does not match the current LLM Cost Tracker schema."
        @setup_details = period_total_errors + [
          "run bin/rails generate llm_cost_tracker:add_period_totals && bin/rails db:migrate"
        ]
        render template: "llm_cost_tracker/shared/setup_required"
        return
      end

      service_charge_errors = LlmCostTracker::Ledger::Schema::ServiceCharges.current_schema_errors
      return if service_charge_errors.empty?

      @setup_message = "The llm_cost_tracker_service_charges table does not match the current LLM Cost Tracker schema."
      @setup_details = service_charge_errors + [
        "run bin/rails generate llm_cost_tracker:add_billing && bin/rails db:migrate"
      ]
      render template: "llm_cost_tracker/shared/setup_required"
    end

    def render_database_error(error)
      @error = error
      render "llm_cost_tracker/errors/database", status: :internal_server_error
    end

    def render_invalid_filter(error)
      @error_message = error.message
      render "llm_cost_tracker/errors/invalid_filter", status: :bad_request
    end

    def render_not_found
      render "llm_cost_tracker/errors/not_found", status: :not_found
    end
  end
end
