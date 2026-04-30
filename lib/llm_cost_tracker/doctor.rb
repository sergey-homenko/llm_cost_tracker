# frozen_string_literal: true

require_relative "ledger"
require_relative "doctor/check"
require_relative "doctor/ingestion_check"
require_relative "doctor/price_check"
require_relative "generators/llm_cost_tracker/add_token_usage_generator"

module LlmCostTracker
  class Doctor
    COLUMN_GENERATORS = {
      "event_id" => "bin/rails generate llm_cost_tracker:add_ingestion",
      "latency_ms" => "bin/rails generate llm_cost_tracker:add_latency_ms",
      "stream" => "bin/rails generate llm_cost_tracker:add_streaming",
      "usage_source" => "bin/rails generate llm_cost_tracker:add_streaming",
      "provider_response_id" => "bin/rails generate llm_cost_tracker:add_provider_response_id"
    }.merge(
      Generators::AddTokenUsageGenerator::COLUMN_NAMES.to_h do |column|
        [column, "bin/rails generate llm_cost_tracker:add_token_usage"]
      end
    ).freeze

    class << self
      def call
        new.checks
      end

      def report(checks = call)
        (["LLM Cost Tracker doctor"] + checks.map do |check|
          "[#{check.status}] #{check.name}: #{check.message}"
        end).join("\n")
      end

      def healthy?(checks = call)
        checks.none? { |check| check.status == :error }
      end
    end

    def checks
      [
        configuration_check,
        capture_check,
        *integration_checks,
        active_record_check,
        table_check,
        column_check,
        period_totals_check,
        IngestionCheck.new.call,
        PriceCheck.new.call,
        calls_check
      ].compact
    end

    private

    def configuration_check
      config = LlmCostTracker.configuration
      Check.new(:ok, "configuration", "active_record ledger enabled=#{config.enabled}")
    end

    def capture_check
      config = LlmCostTracker.configuration
      unless config.enabled
        return Check.new(:warn, "capture", "tracking is disabled; set config.enabled = true to record calls")
      end

      if config.instrumented_integrations.any?
        return Check.new(
          :ok,
          "capture",
          "SDK integrations enabled: #{config.instrumented_integrations.join(', ')}"
        )
      end

      Check.new(
        :ok,
        "capture",
        "no SDK integrations enabled; Faraday middleware and manual capture remain available"
      )
    end

    def integration_checks
      LlmCostTracker::Integrations.checks.map do |check|
        Check.new(check.status, check.name.to_s, check.message)
      end
    end

    def active_record_check
      return Check.new(:ok, "active_record", "available") if active_record_available?

      Check.new(:error, "active_record", "unavailable")
    end

    def table_check
      return unless active_record_available?
      return Check.new(:ok, "llm_api_calls", "table exists") if llm_api_calls_table?

      Check.new(
        :error,
        "llm_api_calls",
        "missing; run bin/rails generate llm_cost_tracker:install && bin/rails db:migrate"
      )
    end

    def column_check
      return unless llm_api_calls_table?

      errors = LlmCostTracker::Ledger::Call.current_schema_errors
      return Check.new(:ok, "llm_api_calls columns", "current") if errors.empty?

      missing = LlmCostTracker::Ledger::Call.missing_current_schema_columns
      generators = missing.filter_map { |column| COLUMN_GENERATORS[column] }.uniq
      message = "current schema required; #{errors.join('; ')}"
      message = "#{message}; run #{generators.join(' && ')} && bin/rails db:migrate" if generators.any?

      Check.new(:error, "llm_api_calls columns", message)
    end

    def period_totals_check
      return unless llm_api_calls_table?

      errors = LlmCostTracker::Ledger::Schema::PeriodTotals.current_schema_errors
      return Check.new(:ok, "period totals", "llm_cost_tracker_period_totals exists") if errors.empty?

      Check.new(
        :error,
        "period totals",
        "current schema required; #{errors.join('; ')}; " \
        "run bin/rails generate llm_cost_tracker:add_period_totals && bin/rails db:migrate"
      )
    end

    def calls_check
      return unless llm_api_calls_table?

      count = LlmCostTracker::Ledger::Call.count
      return Check.new(:warn, "tracked calls", "none recorded yet") if count.zero?

      latest = LlmCostTracker::Ledger::Call.maximum(:tracked_at)&.utc&.iso8601
      Check.new(:ok, "tracked calls", "#{count} recorded; latest #{latest}")
    end

    def active_record_available?
      LlmCostTracker::Ledger::Call.connection
      true
    rescue LoadError, StandardError
      false
    end

    def llm_api_calls_table?
      active_record_available? && table_exists?("llm_api_calls")
    end

    def table_exists?(name)
      LlmCostTracker::Ledger::Call.connection.data_source_exists?(name)
    rescue StandardError
      false
    end
  end
end
