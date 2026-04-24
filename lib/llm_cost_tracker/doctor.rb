# frozen_string_literal: true

module LlmCostTracker
  class Doctor
    Check = Data.define(:status, :name, :message)
    CORE_COLUMNS = %w[provider model input_tokens output_tokens total_tokens total_cost tags tracked_at].freeze
    FEATURE_COLUMNS = {
      "latency_ms" => "bin/rails generate llm_cost_tracker:add_latency_ms",
      "stream" => "bin/rails generate llm_cost_tracker:add_streaming",
      "usage_source" => "bin/rails generate llm_cost_tracker:add_streaming",
      "provider_response_id" => "bin/rails generate llm_cost_tracker:add_provider_response_id",
      "cache_read_input_tokens" => "bin/rails generate llm_cost_tracker:add_usage_breakdown",
      "cache_write_input_tokens" => "bin/rails generate llm_cost_tracker:add_usage_breakdown",
      "hidden_output_tokens" => "bin/rails generate llm_cost_tracker:add_usage_breakdown",
      "pricing_mode" => "bin/rails generate llm_cost_tracker:add_usage_breakdown"
    }.freeze

    class << self
      def call = new.checks

      def report(checks = call)
        (["LLM Cost Tracker doctor"] + checks.map { |check| format_check(check) }).join("\n")
      end

      def healthy?(checks = call)
        checks.none? { |check| check.status == :error }
      end

      private

      def format_check(check)
        "[#{check.status}] #{check.name}: #{check.message}"
      end
    end

    def checks
      [configuration_check, active_record_check, table_check, column_check, period_totals_check, prices_check,
       calls_check].compact
    end

    private

    def configuration_check
      Check.new(:ok, "configuration", "storage_backend=#{LlmCostTracker.configuration.storage_backend.inspect}")
    end

    def active_record_check
      return Check.new(:ok, "storage", "ActiveRecord storage is disabled") unless active_record_storage?
      return Check.new(:ok, "active_record", "available") if active_record_available?

      Check.new(:error, "active_record", "unavailable; add ActiveRecord/Rails or change storage_backend")
    end

    def table_check
      return unless active_record_storage? && active_record_available?
      return Check.new(:ok, "llm_api_calls", "table exists") if llm_api_calls_table?

      Check.new(
        :error,
        "llm_api_calls",
        "missing; run bin/rails generate llm_cost_tracker:install && bin/rails db:migrate"
      )
    end

    def column_check
      return unless active_record_storage? && llm_api_calls_table?

      columns = column_names("llm_api_calls")
      missing_core = CORE_COLUMNS - columns
      missing_features = FEATURE_COLUMNS.keys - columns
      if missing_core.any?
        return Check.new(:error, "llm_api_calls columns", "missing core columns: #{missing_core.join(', ')}")
      end
      if missing_features.any?
        return Check.new(
          :warn,
          "llm_api_calls columns",
          "missing optional columns; run #{feature_generators(missing_features).join(' && ')}"
        )
      end

      Check.new(:ok, "llm_api_calls columns", "current")
    end

    def period_totals_check
      return unless active_record_storage? && llm_api_calls_table?
      if table_exists?("llm_cost_tracker_period_totals")
        return Check.new(:ok, "period totals", "llm_cost_tracker_period_totals exists")
      end

      Check.new(:warn, "period totals", "missing; budget preflight falls back to llm_api_calls sums")
    end

    def prices_check
      path = LlmCostTracker.configuration.prices_file
      return Check.new(:warn, "prices", "using bundled prices; configure prices_file for production") unless path

      count = LlmCostTracker::PriceRegistry.file_prices(path).size
      Check.new(:ok, "prices", "loaded #{count} models from #{path}")
    rescue LlmCostTracker::Error => e
      Check.new(:error, "prices", e.message)
    end

    def calls_check
      return unless active_record_storage? && llm_api_calls_table?

      count = LlmCostTracker::LlmApiCall.count
      return Check.new(:warn, "tracked calls", "none recorded yet") if count.zero?

      latest = LlmCostTracker::LlmApiCall.maximum(:tracked_at)&.utc&.iso8601
      Check.new(:ok, "tracked calls", "#{count} recorded; latest #{latest}")
    end

    def active_record_storage? = LlmCostTracker.configuration.storage_backend == :active_record

    def active_record_available?
      require_relative "llm_api_call" unless defined?(LlmCostTracker::LlmApiCall)
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

    def column_names(table) = LlmCostTracker::LlmApiCall.connection.columns(table).map(&:name)

    def feature_generators(columns) = columns.map { |column| FEATURE_COLUMNS.fetch(column) }.uniq
  end
end
