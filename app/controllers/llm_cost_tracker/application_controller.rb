# frozen_string_literal: true

require "securerandom"

module LlmCostTracker
  class ApplicationController < ActionController::Base
    layout "llm_cost_tracker/application"

    protect_from_forgery with: :exception

    before_action :ensure_current_schema
    before_action :set_dashboard_security_headers

    helper_method :dashboard_csp_nonce

    rescue_from ActiveRecord::ConnectionNotEstablished, with: :render_database_error
    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
    rescue_from ActiveRecord::StatementInvalid, with: :render_database_error
    rescue_from LlmCostTracker::InvalidFilterError, with: :render_invalid_filter

    CORE_SCHEMA_CHECKS = [
      [
        LlmCostTracker::Ledger::Schema::Calls,
        "The llm_cost_tracker_calls table does not match the current LLM Cost Tracker schema."
      ],
      [
        LlmCostTracker::Ledger::Schema::CallLineItems,
        "The llm_cost_tracker_call_line_items table does not match the current LLM Cost Tracker schema."
      ],
      [
        LlmCostTracker::Ledger::Schema::CallTags,
        "The llm_cost_tracker_call_tags table does not match the current LLM Cost Tracker schema."
      ]
    ].freeze

    OPTIONAL_CALL_ROLLUPS_CHECK = [
      LlmCostTracker::Ledger::Schema::CallRollups,
      "The llm_cost_tracker_call_rollups table does not match the current LLM Cost Tracker schema."
    ].freeze

    private_constant :CORE_SCHEMA_CHECKS, :OPTIONAL_CALL_ROLLUPS_CHECK

    private

    def ensure_current_schema
      unless LlmCostTracker::Call.table_exists?
        @setup_message = "The llm_cost_tracker_calls table is not available yet."
        return render template: "llm_cost_tracker/shared/setup_required"
      end

      schema_checks_for_current_config.each do |schema, message|
        errors = schema.current_schema_errors
        next if errors.empty?

        @setup_message = message
        @setup_details = errors + ["See docs/upgrading.md for the migration path."]
        return render template: "llm_cost_tracker/shared/setup_required"
      end

      return unless LlmCostTracker.reconciliation_enabled?

      reconciliation_schema_checks.each do |schema, table, message|
        next unless ActiveRecord::Base.connection.data_source_exists?(table)

        errors = schema.current_schema_errors
        next if errors.empty?

        @setup_message = message
        @setup_details = errors + ["See docs/upgrading.md for the migration path."]
        return render template: "llm_cost_tracker/shared/setup_required"
      end
    end

    def schema_checks_for_current_config
      checks = CORE_SCHEMA_CHECKS.dup
      checks << OPTIONAL_CALL_ROLLUPS_CHECK if LlmCostTracker.configuration.cache_rollups
      checks
    end

    def reconciliation_schema_checks
      LlmCostTracker.const_get(:Reconciliation) # autoload reconciliation + its ledger schemas
      [
        [
          LlmCostTracker::Ledger::Schema::ProviderInvoices,
          "llm_cost_tracker_provider_invoices",
          "The llm_cost_tracker_provider_invoices table does not match the current LLM Cost Tracker schema."
        ],
        [
          LlmCostTracker::Ledger::Schema::ProviderInvoiceImports,
          "llm_cost_tracker_provider_invoice_imports",
          "The llm_cost_tracker_provider_invoice_imports table does not match the current LLM Cost Tracker schema."
        ]
      ]
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

    def set_dashboard_security_headers
      nonce = dashboard_csp_nonce
      response.set_header("X-Frame-Options", "DENY")
      response.set_header("Referrer-Policy", "same-origin")
      response.set_header(
        "Content-Security-Policy",
        "default-src 'self'; style-src 'self' 'nonce-#{nonce}'; img-src 'self' data:; frame-ancestors 'none'"
      )
    end

    def dashboard_csp_nonce
      request.env["llm_cost_tracker.csp_nonce"] ||= SecureRandom.base64(16)
    end
  end
end
