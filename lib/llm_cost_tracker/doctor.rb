# frozen_string_literal: true

require_relative "price_freshness"
require_relative "cost"
require_relative "llm_api_call"
require_relative "token_usage"
require_relative "doctor/capture_check"
require_relative "doctor/ingestion_check"

module LlmCostTracker
  class Doctor
    Check = Data.define(:status, :name, :message)
    CORE_COLUMNS = %w[provider model input_tokens output_tokens total_tokens total_cost tags tracked_at].freeze
    FEATURE_COLUMNS = {
      "latency_ms" => "bin/rails generate llm_cost_tracker:add_latency_ms",
      "stream" => "bin/rails generate llm_cost_tracker:add_streaming",
      "usage_source" => "bin/rails generate llm_cost_tracker:add_streaming",
      "provider_response_id" => "bin/rails generate llm_cost_tracker:add_provider_response_id"
    }.merge(
      (TokenUsage::OPTIONAL_STORED_KEYS + Cost::OPTIONAL_STORED_KEYS + %i[pricing_mode]).to_h do |column|
        [column.to_s, "bin/rails generate llm_cost_tracker:add_token_usage"]
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
        CaptureCheck.call(Check),
        *integration_checks,
        active_record_check,
        table_check,
        column_check,
        period_totals_check,
        IngestionCheck.call(Check),
        prices_check,
        calls_check
      ].compact
    end

    private

    def configuration_check
      config = LlmCostTracker.configuration
      Check.new(:ok, "configuration", "active_record ledger enabled=#{config.enabled}")
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

      columns = LlmCostTracker::LlmApiCall.connection.columns("llm_api_calls").map(&:name)
      missing_core = CORE_COLUMNS - columns
      missing_features = FEATURE_COLUMNS.keys - columns
      if missing_core.any?
        return Check.new(:error, "llm_api_calls columns", "missing core columns: #{missing_core.join(', ')}")
      end

      if missing_features.any?
        generators = missing_features.map { |column| FEATURE_COLUMNS.fetch(column) }.uniq
        return Check.new(
          :warn,
          "llm_api_calls columns",
          "missing optional columns; run #{generators.join(' && ')}"
        )
      end

      Check.new(:ok, "llm_api_calls columns", "current")
    end

    def period_totals_check
      return unless llm_api_calls_table?
      if table_exists?("llm_cost_tracker_period_totals")
        return Check.new(:ok, "period totals", "llm_cost_tracker_period_totals exists")
      end

      Check.new(:warn, "period totals", "missing; budget preflight falls back to llm_api_calls sums")
    end

    def prices_check
      path = LlmCostTracker.configuration.prices_file
      unless path
        return Check.new(
          :warn,
          "prices",
          "using bundled prices updated_at=#{LlmCostTracker::PriceRegistry.metadata.fetch('updated_at', 'unknown')}; " \
          "configure prices_file for production"
        )
      end

      count = LlmCostTracker::PriceRegistry.file_prices(path).size
      metadata = LlmCostTracker::PriceRegistry.file_metadata(path)
      status, freshness = LlmCostTracker::PriceFreshness.call(metadata)
      Check.new(status, "prices", "loaded #{count} models from #{path}; #{freshness}")
    rescue LlmCostTracker::Error => e
      Check.new(:error, "prices", e.message)
    end

    def calls_check
      return unless llm_api_calls_table?

      count = LlmCostTracker::LlmApiCall.count
      return Check.new(:warn, "tracked calls", "none recorded yet") if count.zero?

      latest = LlmCostTracker::LlmApiCall.maximum(:tracked_at)&.utc&.iso8601
      Check.new(:ok, "tracked calls", "#{count} recorded; latest #{latest}")
    end

    def active_record_available?
      LlmCostTracker::LlmApiCall.connection
      true
    rescue LoadError, StandardError
      false
    end

    def llm_api_calls_table?
      active_record_available? && table_exists?("llm_api_calls")
    end

    def table_exists?(name)
      LlmCostTracker::LlmApiCall.connection.data_source_exists?(name)
    rescue StandardError
      false
    end
  end
end
