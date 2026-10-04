# frozen_string_literal: true

require "date"
require "json"

require_relative "../../lib/llm_cost_tracker"
require_relative "fetcher"
require_relative "providers/litellm"

module LlmCostTracker
  module Pricing::Scrape
    class CrossCheck
      REPOSITORY = "https://github.com/BerriAI/litellm.git"
      PRICES_URL = "https://raw.githubusercontent.com/BerriAI/litellm/%s/model_prices_and_context_window.json"
      REGISTRY_PATH = File.expand_path("../../lib/llm_cost_tracker/prices.json", __dir__)
      FULLY_SCRAPED = %w[anthropic gemini openai openrouter xai].freeze
      TOLERANCE = 0.01
      DATED_SUFFIX = /-(?:\d{4}-\d{2}-\d{2}|\d{8})\z/
      TIERS = [*Providers::Litellm::TIERS.values, "fast"].freeze
      TIERED_FIELD = /\A(?<context>above_context_)?(?:(?<tier>#{TIERS.join('|')})_)?(?<dimension>.+)\z/

      class Error < StandardError; end

      def self.run(report_path:, issue_path:, registry_path: REGISTRY_PATH, fetcher: Fetcher.new, sha: nil)
        sha ||= IO.popen(["git", "ls-remote", REPOSITORY, "refs/heads/main"], &:read)[/\A\h{40}/]
        raise Error, "LiteLLM main commit not found" unless sha

        check = new(registry: JSON.parse(File.read(registry_path)),
                    catalogue: JSON.parse(fetcher.get(format(PRICES_URL, sha)).body))
        File.write(report_path, "## Cross-source check (LiteLLM #{sha[0, 8]})\n\n#{check.summary}\n#{check.findings}")
        File.write(issue_path, check.findings)
      end

      def initialize(registry:, catalogue:, today: Date.today)
        @ours = registry.fetch("models", {})
        @charges = registry.fetch("service_charges", {})
        @conversion = Providers::Litellm.convert(catalogue)
        @today = today.iso8601
        @counts = Hash.new { |counts, provider| counts[provider] = Hash.new(0) }
        @differences = []
        @field_gaps = {}
        compare
      end

      def summary
        rows = @counts.sort.map do |provider, count|
          compared = count[:equal] + count[:differ]
          "| #{provider} | #{compared} | #{count[:equal]} | #{count[:differ]} | #{count[:litellm_only]} | " \
            "#{count[:ours_only]} |"
        end
        ["| provider | compared | equal | differ | LiteLLM-only models | ours-only models |",
         "|---|---|---|---|---|---|", *rows].join("\n") << "\n"
      end

      def findings
        {
          "Values that differ by more than 1% (official kept)" => difference_lines,
          "LiteLLM-only models of fully scraped providers" => model_gap_lines,
          "LiteLLM-only fields on covered models" => field_gap_lines,
          "Unknown LiteLLM fields" => @conversion.unknown.sort.map do |field, models|
            "- `#{field}` (#{models.size}): #{models.first(3).join(', ')}"
          end,
          "Not representable" => @conversion.unrepresentable.sort.map do |reason, models|
            "- #{reason}: #{models.join(', ')}"
          end
        }.reject { |_, lines| lines.empty? }.map { |title, lines| "### #{title}\n\n#{lines.join("\n")}\n" }.join("\n")
      end

      private

      def compare
        providers = (@ours.keys + @conversion.models.keys).map { |key| key.split("/").first }.uniq
        providers.each do |provider|
          ours = models_of(@ours, provider)
          theirs = models_of(@conversion.models, provider)
          (ours & theirs).each { |model| compare_model(provider, model) }
          @counts[provider][:litellm_only] = (theirs - ours).size
          @counts[provider][:ours_only] = (ours - theirs).size
        end
      end

      def compare_model(provider, model)
        prices = @ours.fetch(model)
        gaps = @conversion.models.fetch(model).filter_map do |field, value|
          mine = our_value(provider, prices, field)
          next "`#{field}`" if mine.nil?

          different = differ?(mine, value)
          @counts[provider][different ? :differ : :equal] += 1
          @differences << [model, field, mine, value] if different
          nil
        end
        uplift = Providers::Litellm.uplift(@conversion.entries.fetch(model))
        if uplift && prices.keys.none? { |field| field.include?("data_residency") }
          gaps << "`data_residency_*` (x#{uplift})"
        end
        @field_gaps[model] = gaps.sort if gaps.any?
      end

      def our_value(provider, prices, field)
        return prices[field] if prices.key?(field)

        context, tier, dimension = TIERED_FIELD.match(field).values_at(:context, :tier, :dimension)
        return @charges.dig(provider, field) unless context || tier
        return unless tier && !%w[input output].include?(dimension)

        standard, input, tier_input = prices.values_at(
          "#{context}#{dimension}",
          "#{context}input",
          "#{context}#{tier}_input"
        )
        standard * tier_input / input if standard && tier_input && input.to_f.positive?
      end

      def differ?(ours, theirs)
        return ours != theirs if ours.zero? || theirs.zero?

        (ours - theirs).abs / [ours.abs, theirs.abs].max > TOLERANCE
      end

      def difference_lines
        return [] if @differences.empty?

        rows = @differences.sort.map do |model, field, ours, theirs|
          change = ours.zero? ? "" : format("%+.0f%%", (theirs - ours) * 100.0 / ours)
          "| #{model} | `#{field}` | #{ours} | #{theirs} | #{change} |"
        end
        ["| model | field | ours | LiteLLM | change |", "|---|---|---|---|---|", *rows]
      end

      def model_gap_lines
        FULLY_SCRAPED.filter_map do |provider|
          gaps = (models_of(@conversion.models, provider) - models_of(@ours, provider)).select { |model| gap?(model) }
          "- #{provider}: #{gaps.sort.join(', ')}" if gaps.any?
        end
      end

      def gap?(model)
        entry = @conversion.entries.fetch(model)
        fields = @conversion.models.fetch(model)
        retired = entry["deprecation_date"].to_s
        return false if !retired.empty? && retired < @today

        token_mode = Providers::Litellm::TOKEN_MODES.include?(entry["mode"])
        return false if token_mode && !(fields["input"] && fields["output"])

        !dated_twin?(model, fields)
      end

      def dated_twin?(model, fields)
        return false unless model.match?(DATED_SUFFIX)

        base = model.sub(DATED_SUFFIX, "")
        ours = @ours[base]
        @conversion.models[base] == fields ||
          (ours && fields.none? { |field, value| ours.key?(field) && differ?(ours[field], value) })
      end

      def field_gap_lines
        @field_gaps.group_by { |_, gaps| gaps }
                   .map { |gaps, models| "- #{gaps.join(', ')}: #{models.map(&:first).join(', ')}" }
                   .sort
      end

      def models_of(table, provider)
        table.keys.select { |key| key.start_with?("#{provider}/") }
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  LlmCostTracker::Pricing::Scrape::CrossCheck.run(report_path: ARGV.fetch(0), issue_path: ARGV.fetch(1))
end
