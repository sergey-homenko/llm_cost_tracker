# frozen_string_literal: true

require "securerandom"

module LlmCostTracker
  class ApplicationController < ActionController::Base
    layout "llm_cost_tracker/application"

    protect_from_forgery with: :exception

    before_action :set_dashboard_security_headers
    before_action :ensure_current_schema
    before_action :assign_dashboard_date_range

    helper_method :dashboard_csp_nonce

    rescue_from ActiveRecord::ConnectionNotEstablished, with: :render_database_error
    rescue_from ActiveRecord::AdapterNotSpecified, with: :render_database_error
    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
    rescue_from ActiveRecord::StatementInvalid, with: :render_database_error
    rescue_from LlmCostTracker::InvalidFilterError, with: :render_invalid_filter

    private

    def ensure_current_schema
      drift = LlmCostTracker::Dashboard::SetupState.current
      return unless drift

      @setup_message = drift.message
      @setup_details = drift.details
      return head :service_unavailable unless request.format.html?

      render template: "llm_cost_tracker/shared/setup_required"
    end

    def assign_dashboard_date_range
      range = LlmCostTracker::Dashboard::DateRange.call(params: params)
      @from_date = range.from
      @to_date = range.to
    end

    def render_database_error(_error)
      render "llm_cost_tracker/errors/database", status: :internal_server_error
    end

    def render_invalid_filter(error)
      @error_message = error.message
      render "llm_cost_tracker/errors/invalid_filter", status: :bad_request
    end

    def render_not_found
      render "llm_cost_tracker/errors/not_found", status: :not_found
    end

    def set_dashboard_security_headers
      nonce = dashboard_csp_nonce
      response.headers["X-Frame-Options"] = "DENY"
      response.headers["Referrer-Policy"] = "same-origin"
      response.headers["Content-Security-Policy"] = [
        "default-src 'self'",
        "script-src 'self' 'nonce-#{nonce}'",
        "style-src 'self' 'nonce-#{nonce}'",
        "img-src 'self' data:",
        "frame-ancestors 'none'"
      ].join("; ")
    end

    def dashboard_csp_nonce
      request.env["llm_cost_tracker.csp_nonce"] ||= SecureRandom.base64(16)
    end
  end
end
