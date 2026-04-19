# frozen_string_literal: true

require "llm_cost_tracker/llm_api_call"
require_relative "../../services/llm_cost_tracker/dashboard/errors"

module LlmCostTracker
  class ApplicationController < ActionController::Base
    protect_from_forgery with: :exception

    layout "llm_cost_tracker/application"

    before_action :ensure_llm_api_calls_table

    rescue_from ActiveRecord::ConnectionNotEstablished, with: :render_database_error
    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
    rescue_from ActiveRecord::StatementInvalid, with: :render_database_error
    rescue_from LlmCostTracker::Dashboard::InvalidFilter, with: :render_invalid_filter

    private

    def ensure_llm_api_calls_table
      return if llm_api_calls_table_available?

      render template: "llm_cost_tracker/shared/setup_required"
    end

    def llm_api_calls_table_available?
      LlmCostTracker::LlmApiCall.table_exists?
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid
      false
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
