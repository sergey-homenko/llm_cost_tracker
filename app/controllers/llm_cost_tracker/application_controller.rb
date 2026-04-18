# frozen_string_literal: true

module LlmCostTracker
  class ApplicationController < ActionController::Base
    protect_from_forgery with: :exception

    layout "llm_cost_tracker/application"

    rescue_from ActiveRecord::ConnectionNotEstablished, with: :render_database_error
    rescue_from ActiveRecord::StatementInvalid, with: :render_database_error

    helper_method :llm_api_calls_table_available?

    private

    def llm_api_calls_table_available?
      LlmCostTracker::LlmApiCall.table_exists?
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid
      false
    end

    def render_database_error(error)
      @error = error
      render "llm_cost_tracker/errors/database", status: :internal_server_error
    end
  end
end
