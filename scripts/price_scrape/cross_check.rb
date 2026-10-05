# frozen_string_literal: true

require "date"
require "json"
require "yaml"

require_relative "../../lib/llm_cost_tracker"
require_relative "fetcher"
require_relative "providers/gemini"
require_relative "providers/litellm"

module LlmCostTracker
  module Pricing::Scrape
    class CrossCheck
      REPOSITORY = "https://github.com/BerriAI/litellm.git"
      PRICES_URL = "https://raw.githubusercontent.com/BerriAI/litellm/%s/model_prices_and_context_window.json"
      REGISTRY_PATH = File.expand_path("../../lib/llm_cost_tracker/prices.json", __dir__)
      ACKNOWLEDGED_PATH = File.expand_path("cross_check_acknowledged.yml", __dir__)
      FULLY_SCRAPED = %w[anthropic gemini openai openrouter xai].freeze
      COUNTS_ONLY = %w[openrouter].freeze
      UNCAPTURED = { "gemini" => Providers::Gemini::UNCAPTURED_MODEL }.freeze
      UNCOMPARED = { "openai" => %w[web_search_request] }.freeze
      TOLERANCE = 0.01
      DATED_SUFFIX = /-(?:\d{4}-\d{2}-\d{2}|\d{8})\z/
      TIERS = [*Providers::Litellm::TIERS.values, "fast"].freeze
      TIERED_FIELD = /\A(?<context>above_context_)?(?:(?<tier>#{TIERS.join('|')})_)?(?<dimension>.+)\z/
      SECTIONS = {
        notes: "Scraper notes",
        difference: "Values that differ by more than 1% (official kept)",
        model: "LiteLLM-only models of fully scraped providers",
        field: "LiteLLM-only fields on covered models",
        unknown: "Unknown LiteLLM fields",
        unrepresentable: "Not representable",
        stale: "Stale acknowledgements"
      }.freeze
      Finding = Data.define(:section, :model, :field, :detail)

      class Error < StandardError; end

      def self.run(
        report_path:,
        issue_path:,
        registry_path: REGISTRY_PATH,
        acknowledged_path: ACKNOWLEDGED_PATH,
        notes_path: nil,
        fetcher: Fetcher.new,
        sha: nil
      )
        sha ||= IO.popen(["git", "ls-remote", REPOSITORY, "refs/heads/main"], &:read)[/\A\h{40}/]
        raise Error, "LiteLLM main commit not found" unless sha

        check = new(registry: JSON.parse(File.read(registry_path)),
                    catalogue: JSON.parse(fetcher.get(format(PRICES_URL, sha)).body),
                    acknowledged: YAML.safe_load_file(acknowledged_path) || {},
                    notes: notes_path && File.exist?(notes_path) ? File.readlines(notes_path, chomp: true) : [])
        File.write(report_path, check.report(sha))
        File.write(issue_path, check.findings)
      end

      def initialize(registry:, catalogue:, acknowledged: {}, notes: [], today: Date.today)
        @ours = registry.fetch("models", {})
        @notes = notes
        @charges = registry.fetch("service_charges", {})
        @conversion = Providers::Litellm.convert(catalogue)
        @acknowledged = acknowledged
        @today = today.iso8601
        @counts = Hash.new { |counts, provider| counts[provider] = Hash.new(0) }
        @findings = []
        compare
        @conversion.unknown.each { |name, models| models.each { |model| add(:unknown, model, name) } }
        @conversion.unrepresentable.each do |reason, models|
          models.each { |model| add(:unrepresentable, model, nil, reason) }
        end
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
        open = reported.reject { |finding| acknowledgement(finding) }.group_by(&:section)
        SECTIONS.filter_map do |section, title|
          lines = lines(section, open)
          "### #{title}\n\n#{lines.join("\n")}\n" if lines.any?
        end.join("\n")
      end

      def report(sha)
        acknowledged = reported.filter_map { |finding| acknowledgement(finding) }.uniq.sort
        details = acknowledged.map { |key| "- `#{key}`: #{@acknowledged.fetch(key)}" }
        heading = "<summary>Acknowledged (#{details.size})</summary>"
        block = "\n<details>\n#{heading}\n\n#{details.join("\n")}\n\n</details>\n"
        "## Cross-source check (LiteLLM #{sha[0, 8]})\n\n#{summary}\n#{findings}#{block if details.any?}"
      end

      private

      def add(section, model, field = nil, detail = nil)
        @findings << Finding.new(section:, model:, field:, detail:)
      end

      def reported
        @findings.reject do |finding|
          provider = finding.model.split("/").first
          COUNTS_ONLY.include?(provider) || UNCAPTURED[provider]&.match?(finding.model)
        end
      end

      def acknowledgement(finding)
        ["#{finding.model}.#{finding.field}", finding.model].find { |key| @acknowledged.key?(key) }
      end

      def stale
        @acknowledged.keys - reported.filter_map { |finding| acknowledgement(finding) }
      end

      def compare
        (@ours.keys + @conversion.models.keys).map { |key| key.split("/").first }.uniq.each do |provider|
          ours = models_of(@ours, provider)
          theirs = models_of(@conversion.models, provider)
          (ours & theirs).each { |model| compare_model(provider, model) }
          @counts[provider][:litellm_only] = (theirs - ours).size
          @counts[provider][:ours_only] = (ours - theirs).size
          gaps = FULLY_SCRAPED.include?(provider) ? (theirs - ours).select { |model| gap?(provider, model) } : []
          gaps.each { |model| add(:model, model) }
        end
      end

      def compare_model(provider, model)
        prices = @ours.fetch(model)
        @conversion.models.fetch(model).each do |field, value|
          next unless compared?(provider, field)

          mine = our_value(provider, prices, field)
          next add(:field, model, field) if mine.nil?

          different = differ?(mine, value)
          @counts[provider][different ? :differ : :equal] += 1
          add(:difference, model, field, [mine, value]) if different
        end
        uplift = Providers::Litellm.uplift(@conversion.entries.fetch(model))
        return unless uplift && prices.keys.none? { |key| key.include?("data_residency") }

        add(:field, model, "data_residency_*", uplift)
      end

      def compared?(provider, field)
        field != Pricing::Registry::CONTEXT_THRESHOLD_KEY && !UNCOMPARED.fetch(provider, []).include?(field)
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

      def gap?(provider, model)
        entry = @conversion.entries.fetch(model)
        fields = @conversion.models.fetch(model)
        retired = entry["deprecation_date"].to_s
        return false if !retired.empty? && retired < @today

        token_mode = Providers::Litellm::TOKEN_MODES.include?(entry["mode"])
        return false if token_mode && !(fields["input"] && fields["output"])

        !dated_twin?(provider, model, fields)
      end

      def dated_twin?(provider, model, fields)
        return false unless model.match?(DATED_SUFFIX)

        base = model.sub(DATED_SUFFIX, "")
        return true if @conversion.models[base] == fields

        ours = @ours[base]
        return false unless ours

        fields.none? { |field, value| compared?(provider, field) && ours.key?(field) && differ?(ours[field], value) }
      end

      def lines(section, open)
        found = open.fetch(section, [])
        case section
        when :notes then @notes
        when :stale then stale.map { |key| "- `#{key}` no longer matches a finding" }
        when :difference then difference_lines(found)
        when :model then grouped(found) { |finding| finding.model.split("/").first }
        when :field then field_gap_lines(found)
        when :unknown then found.group_by(&:field).sort.map { |name, list| unknown_line(name, list) }
        else grouped(found, &:detail)
        end
      end

      def difference_lines(found)
        return [] if found.empty?

        rows = found.sort_by { |finding| [finding.model, finding.field] }.map do |finding|
          ours, theirs = finding.detail
          change = ours.zero? ? "" : format("%+.0f%%", (theirs - ours) * 100.0 / ours)
          "| #{finding.model} | `#{finding.field}` | #{ours} | #{theirs} | #{change} |"
        end
        ["| model | field | ours | LiteLLM | change |", "|---|---|---|---|---|", *rows]
      end

      def field_gap_lines(found)
        gaps = found.group_by(&:model).transform_values do |list|
          list.map { |finding| "`#{finding.field}`#{" (x#{finding.detail})" if finding.detail}" }.sort
        end
        gaps.group_by(&:last).map { |list, models| "- #{list.join(', ')}: #{models.map(&:first).sort.join(', ')}" }.sort
      end

      def unknown_line(name, list)
        "- `#{name}` (#{list.size}): #{list.map(&:model).first(3).join(', ')}"
      end

      def grouped(found, &)
        found.group_by(&).sort.map { |label, list| "- #{label}: #{list.map(&:model).sort.join(', ')}" }
      end

      def models_of(table, provider)
        table.keys.select { |key| key.start_with?("#{provider}/") }
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  LlmCostTracker::Pricing::Scrape::CrossCheck.run(
    report_path: ARGV.fetch(0),
    issue_path: ARGV.fetch(1),
    notes_path: ARGV[2]
  )
end
