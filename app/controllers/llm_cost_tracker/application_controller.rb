# frozen_string_literal: true

module LlmCostTracker
  class ApplicationController < ActionController::Base
    layout "llm_cost_tracker/application"

    before_action :ensure_current_schema

    rescue_from ActiveRecord::ConnectionNotEstablished, with: :render_database_error
    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
    rescue_from ActiveRecord::StatementInvalid, with: :render_database_error
    rescue_from LlmCostTracker::InvalidFilterError, with: :render_invalid_filter

    SCHEMA_CHECKS = [
      [
        LlmCostTracker::Ledger::Schema::Calls,
        "The llm_cost_tracker_calls table does not match the current LLM Cost Tracker schema.",
        []
      ],
      [
        LlmCostTracker::Ledger::Schema::CallRollups,
        "The llm_cost_tracker_call_rollups table does not match the current LLM Cost Tracker schema.",
        ["run bin/rails generate llm_cost_tracker:add_call_rollups && bin/rails db:migrate"]
      ],
      [
        LlmCostTracker::Ledger::Schema::CallLineItems,
        "The llm_cost_tracker_call_line_items table does not match the current LLM Cost Tracker schema.",
        []
      ],
      [
        LlmCostTracker::Ledger::Schema::CallTags,
        "The llm_cost_tracker_call_tags table does not match the current LLM Cost Tracker schema.",
        []
      ]
    ].freeze

    private_constant :SCHEMA_CHECKS

    private

    def ensure_current_schema
      unless LlmCostTracker::Call.table_exists?
        @setup_message = "The llm_cost_tracker_calls table is not available yet."
        return render template: "llm_cost_tracker/shared/setup_required"
      end

      SCHEMA_CHECKS.each do |schema, message, extra_details|
        errors = schema.current_schema_errors
        next if errors.empty?

        @setup_message = message
        @setup_details = errors + extra_details
        return render template: "llm_cost_tracker/shared/setup_required"
      end
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
