# frozen_string_literal: true

require_relative "ledger"
require_relative "check"
require_relative "doctor/probe"
require_relative "doctor/ingestion_check"
require_relative "doctor/price_check"
require_relative "doctor/schema_check"

module LlmCostTracker
  class Doctor
    autoload :CaptureVerifier,            "llm_cost_tracker/doctor/capture_verifier"

    STATUS_GLYPHS = { ok: "✓", warn: "!", error: "x" }.freeze
    STATUS_COLORS = { ok: 32, warn: 33, error: 31 }.freeze

    SECTIONS = %w[Setup Schema Operations].freeze

    SECTION_FOR_CHECK = {
      "configuration" => "Setup",
      "capture" => "Setup",
      "active_record" => "Schema",
      "llm_cost_tracker_calls" => "Schema",
      "llm_cost_tracker_calls columns" => "Schema",
      "call line items" => "Schema",
      "call tags" => "Schema",
      "call rollups" => "Operations",
      "inline ingestion" => "Operations",
      "async ingestion" => "Operations",
      "prices" => "Operations",
      "tracked calls" => "Operations"
    }.freeze

    private_constant :STATUS_GLYPHS, :STATUS_COLORS, :SECTIONS, :SECTION_FOR_CHECK

    class << self
      def call
        new.checks
      end

      def report(checks = call, color: $stdout.tty?)
        name_width = checks.map { |c| c.name.length }.max.to_i

        lines = [bold("LLM Cost Tracker doctor", color), ""]
        each_section(checks) do |section, members|
          lines << bold(section, color)
          members.each do |check|
            status = paint_status("[#{STATUS_GLYPHS.fetch(check.status, check.status)}]", check.status, color)
            lines << "  #{status} #{"#{check.name}:".ljust(name_width + 1)} #{check.message}"
          end
          lines << ""
        end
        lines.pop if lines.last == ""
        lines.join("\n")
      end

      def healthy?(checks = call)
        checks.none? { |check| check.status == :error }
      end

      private

      def each_section(checks)
        SECTIONS.each do |section|
          members = checks.select { |c| (SECTION_FOR_CHECK[c.name] || "Setup") == section }
          next if members.empty?

          yield section, members
        end
      end

      def paint_status(text, status, color)
        return text unless color && STATUS_COLORS.key?(status)

        "\e[#{STATUS_COLORS[status]}m#{text}\e[0m"
      end

      def bold(text, color)
        return text unless color

        "\e[1m#{text}\e[0m"
      end
    end

    def checks
      [
        configuration_check,
        capture_check,
        *LlmCostTracker::Integrations.checks,
        active_record_check,
        table_check,
        column_check,
        *dependent_core_schema_checks,
        call_rollups_check,
        IngestionCheck.new.call,
        PriceCheck.new.call,
        calls_check
      ].compact
    end

    private

    def dependent_core_schema_checks
      Ledger::Schema::CORE_SCHEMAS.reject { |schema, _| schema == Ledger::Schema::Calls }.map do |schema, table|
        SchemaCheck.new(name: table.delete_prefix("llm_cost_tracker_").tr("_", " "),
                        schema: schema,
                        table: table).call
      end
    end

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
          "SDK integrations enabled: #{config.instrumented_integrations.to_a.join(', ')}"
        )
      end

      Check.new(
        :ok,
        "capture",
        "no SDK integrations enabled; Faraday middleware and manual capture remain available"
      )
    end

    def active_record_check
      return Check.new(:ok, "active_record", "available") if active_record_available?

      Check.new(:error, "active_record", "unavailable")
    end

    def table_check
      return unless active_record_available?
      return Check.new(:ok, "llm_cost_tracker_calls", "table exists") if llm_cost_tracker_calls_table?

      Check.new(
        :error,
        "llm_cost_tracker_calls",
        "missing; run bin/rails generate llm_cost_tracker:install && bin/rails db:migrate"
      )
    end

    def column_check
      return unless llm_cost_tracker_calls_table?

      errors = LlmCostTracker::Ledger::Schema::Calls.current_schema_errors
      return Check.new(:ok, "llm_cost_tracker_calls columns", "current") if errors.empty?

      Check.new(
        :error,
        "llm_cost_tracker_calls columns",
        "schema mismatch: #{errors.join('; ')}; see docs/upgrading.md"
      )
    end

    def call_rollups_check
      return unless llm_cost_tracker_calls_table?
      return live_rollups_check unless LlmCostTracker.configuration.cache_rollups

      errors = LlmCostTracker::Ledger::Schema::CallRollups.current_schema_errors
      return Check.new(:ok, "call rollups", "llm_cost_tracker_call_rollups exists") if errors.empty?

      Check.new(
        :error,
        "call rollups",
        "schema mismatch: #{errors.join('; ')}; see docs/upgrading.md"
      )
    end

    def live_rollups_check
      if Probe.table_exists?("llm_cost_tracker_call_rollups")
        Check.new(
          :warn,
          "call rollups",
          "cache_rollups=false but llm_cost_tracker_call_rollups exists. " \
          "Set config.cache_rollups = true to keep budget reads on the rollups fast path or drop the table."
        )
      else
        Check.new(
          :ok,
          "call rollups",
          "cache_rollups=false; budget reads aggregate from llm_cost_tracker_calls directly"
        )
      end
    end

    def calls_check
      return unless llm_cost_tracker_calls_table?

      snapshot = LlmCostTracker::Call
                 .select("COUNT(*) AS tracked_call_count, MAX(tracked_at) AS latest_tracked_at")
                 .take
      count = snapshot.tracked_call_count.to_i
      return Check.new(:warn, "tracked calls", "none recorded yet") if count.zero?

      latest = snapshot.latest_tracked_at.to_time.utc.iso8601
      Check.new(:ok, "tracked calls", "#{count} recorded; latest #{latest}")
    end

    def active_record_available?
      LlmCostTracker::Call.connection
      true
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError
      false
    end

    def llm_cost_tracker_calls_table? = active_record_available? && Probe.table_exists?("llm_cost_tracker_calls")
  end
end
