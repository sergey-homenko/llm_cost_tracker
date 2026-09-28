# frozen_string_literal: true

require "json"

module AccountingGolden
  FIXTURES = File.expand_path("../fixtures/accounting", __dir__)
  PRICES_PATH = File.join(FIXTURES, "prices.json")
  EXPECTED_PATH = File.join(FIXTURES, "expected.jsonl")
  RUBY_LLM_1_PATH = File.join(FIXTURES, "expected_ruby_llm_1.jsonl")
  CAPTURED_AT = Time.utc(2026, 9, 28, 12)
  TOKEN_COLUMNS = LlmCostTracker::Usage::TokenUsage.members.map(&:to_s).freeze
  CALL_FIELDS = (%w[provider model pricing_mode stream batch usage_source cost_status total_cost] +
                 TOKEN_COLUMNS + %w[provider_response_id]).freeze
  LINE_ITEM_FIELDS = %w[kind direction cache_state quantity rate_amount cost cost_status].freeze
  ROLLUP_FIELDS = %w[period provider currency total_cost].freeze

  class << self
    def ruby_llm_1? = RubyLLM::VERSION.start_with?("1.")

    def update? = ENV["LCT_ACCOUNTING_UPDATE"] == "1"

    def expected
      @expected ||= ruby_llm_1? ? read(EXPECTED_PATH).merge(read(RUBY_LLM_1_PATH)) : read(EXPECTED_PATH)
    end

    def actual = @actual ||= {}

    def recorded
      rows = LlmCostTracker::Call.order(:id).map do |call|
        line_items = call.line_items.order(:position).map { |item| json_values(item, LINE_ITEM_FIELDS) }
        tags = call.tag_records.pluck(:key, :value).sort
        json_values(call, CALL_FIELDS).merge("line_items" => line_items, "tags" => tags)
      end
      rollups = LlmCostTracker::CallRollup.order(:period, :provider).map { |rollup| json_values(rollup, ROLLUP_FIELDS) }
      { "rows" => rows, "rollups" => rollups }
    end

    def differences(expected, actual)
      expected_values = flatten(expected)
      actual_values = flatten(actual)
      (expected_values.keys | actual_values.keys).filter_map do |path|
        wanted = shown(expected_values, path)
        got = shown(actual_values, path)
        "#{path}: expected #{wanted}, got #{got}" unless wanted == got
      end
    end

    def write_updates(case_names)
      if ruby_llm_1?
        base = read(EXPECTED_PATH)
        variants = read(RUBY_LLM_1_PATH).slice(*case_names).merge(actual).reject { |name, entry| base[name] == entry }
        write(RUBY_LLM_1_PATH, variants)
      else
        write(EXPECTED_PATH, read(EXPECTED_PATH).slice(*case_names).merge(actual))
      end
    end

    private

    def json_values(record, fields)
      fields.to_h do |field|
        value = record[field]
        [field, value.is_a?(BigDecimal) ? value.to_s("F") : value]
      end
    end

    def flatten(value, path = nil, into = {})
      case value
      when Hash then value.each { |key, nested| flatten(nested, path ? "#{path}.#{key}" : key, into) }
      when Array then value.each_with_index { |nested, index| flatten(nested, "#{path}[#{index}]", into) }
      else into[path] = value
      end
      into
    end

    def shown(values, path) = values.key?(path) ? values[path].inspect : "nothing"

    def read(path)
      return {} unless File.exist?(path)

      File.readlines(path, chomp: true).to_h do |line|
        entry = JSON.parse(line)
        [entry.delete("case"), entry]
      end
    end

    def write(path, entries)
      File.write(path, entries.sort.map { |name, snapshot| "#{JSON.generate({ "case" => name, **snapshot })}\n" }.join)
    end
  end
end
