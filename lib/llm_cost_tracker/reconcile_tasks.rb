# frozen_string_literal: true

require "json"

require_relative "reconciliation"

module LlmCostTracker
  module ReconcileTasks
    SOURCE_PARSERS = {
      "openai" => Reconciliation::Sources::OpenaiUsage,
      "anthropic" => Reconciliation::Sources::AnthropicUsage
    }.freeze
    GENERIC_SOURCES = %w[csv].freeze

    module_function

    def run_import(env: ENV, output: $stdout, error_output: $stderr)
      result = import_from_env(env: env)
      output.puts "llm_cost_tracker: imported #{result.total_imported} rows " \
                  "(inserted=#{result.inserted}, updated=#{result.updated}, skipped=#{result.skipped})"
      result.errors.each { |error| error_output.puts "  error: #{error}" }
      raise "llm_cost_tracker: reconcile import had errors" unless result.success?

      result
    end

    def run_diff(env: ENV, output: $stdout)
      diff = diff_from_env(env: env)
      print_diff(diff, output: output)
      diff
    end

    def import_from_env(env: ENV)
      source = required_env(env, "SOURCE")
      input_path = required_env(env, "INPUT")
      raise ArgumentError, "INPUT file not found: #{input_path}" unless File.exist?(input_path)

      payload = JSON.parse(File.read(input_path))
      rows = parse_rows(source: source, payload: payload)
      Reconciliation.import(source: source.to_sym, rows: rows, provider: env["PROVIDER"])
    end

    def diff_from_env(env: ENV)
      source = required_env(env, "SOURCE")
      period_start = Date.parse(required_env(env, "PERIOD_START"))
      period_end = Date.parse(required_env(env, "PERIOD_END"))
      Reconciliation.diff(source: source.to_sym, period_start: period_start, period_end: period_end,
                          provider: env["PROVIDER"],
                          drilldown_limit: parse_drilldown_limit(env["DRILLDOWN_LIMIT"]))
    end

    def parse_drilldown_limit(value)
      return Reconciliation::Diff::DEFAULT_DRILLDOWN_LIMIT if value.nil? || value.to_s.empty?
      return nil if value.to_s.downcase == "all"

      Integer(value)
    end

    def print_diff(diff, output: $stdout)
      output.puts "llm_cost_tracker: reconciliation diff for #{diff.source} " \
                  "#{diff.period_start}..#{diff.period_end}"
      output.puts "  provider_total: #{diff.provider_total.to_s('F')} #{diff.currency}"
      output.puts "  local_total:    #{diff.local_total.to_s('F')} #{diff.currency} " \
                  "(from #{diff.local_total_source})"
      output.puts "  delta:          #{diff.delta_amount.to_s('F')} (#{diff.delta_percent || 'n/a'}%)"
      print_unmatched_provider_rows(diff, output)
      print_unmatched_local_calls(diff, output)
      print_non_cost_rows(diff, output)
    end

    def parse_rows(source:, payload:)
      parser = SOURCE_PARSERS[source.to_s]
      return parser.parse(payload) if parser
      return Array(payload["rows"]) if GENERIC_SOURCES.include?(source.to_s)

      known = (SOURCE_PARSERS.keys + GENERIC_SOURCES).join(", ")
      raise ArgumentError, "unknown SOURCE #{source.inspect}; known sources: #{known}"
    end

    def required_env(env, key)
      value = env[key].to_s.strip
      raise ArgumentError, "missing #{key}" if value.empty?

      value
    end

    def print_unmatched_provider_rows(diff, output)
      return if diff.unmatched_provider_rows.empty?

      output.puts "  unmatched provider rows#{truncation_suffix(diff.unmatched_provider_rows.size,
                                                                diff.unmatched_provider_rows_total)}:"
      diff.unmatched_provider_rows.each do |row|
        output.puts "    #{row[:external_id]} (#{row[:match_basis]}): " \
                    "#{row[:billed_amount].to_s('F')} #{format_attribution(row[:attribution])}"
      end
    end

    def print_unmatched_local_calls(diff, output)
      return if diff.unmatched_local_calls.empty?

      output.puts "  unmatched local calls#{truncation_suffix(diff.unmatched_local_calls.size,
                                                              diff.unmatched_local_calls_total)}:"
      diff.unmatched_local_calls.each do |row|
        output.puts "    #{row[:count]} calls / #{row[:total_cost].to_s('F')} " \
                    "#{format_attribution(row[:attribution])}"
      end
    end

    def print_non_cost_rows(diff, output)
      return if diff.non_cost_rows.empty?

      output.puts "  non-cost evidence#{truncation_suffix(diff.non_cost_rows.size,
                                                          diff.non_cost_rows_total)}:"
      diff.non_cost_rows.each do |row|
        output.puts "    [#{row[:row_type]}/#{row[:meter]}] #{row[:billed_amount].to_s('F')} " \
                    "#{format_attribution(row[:attribution])}"
      end
    end

    def truncation_suffix(shown, total)
      return "" if shown >= total

      " (showing #{shown} of #{total} — pass DRILLDOWN_LIMIT=all to see every row)"
    end

    def format_attribution(attribution)
      LlmCostTracker::Masking.format_attribution(attribution, separator: ",")
    end
  end
end
