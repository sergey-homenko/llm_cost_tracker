# frozen_string_literal: true

require "date"
require "json"
require "yaml"

require_relative "../../lib/llm_cost_tracker"
require_relative "fetcher"
require_relative "providers/gemini"
require_relative "providers/litellm"
require_relative "cross_check/comparison"

module LlmCostTracker
  module Pricing::Scrape
    class CrossCheck
      REPOSITORY = "https://github.com/BerriAI/litellm.git"
      REGISTRY_PATH = File.expand_path("../../lib/llm_cost_tracker/prices.json", __dir__)
      ACKNOWLEDGED_PATH = File.expand_path("cross_check_acknowledged.yml", __dir__)
      FULLY_SCRAPED = %w[anthropic deepseek gemini openai openrouter xai].freeze
      GATED = %w[cohere mistral].freeze
      COUNTS_ONLY = %w[openrouter].freeze
      UNCAPTURED = { "gemini" => Providers::Gemini::UNCAPTURED_MODEL }.freeze
      UNCOMPARED = { "openai" => %w[web_search_request] }.freeze
      DATED_SUFFIX = Providers::Litellm::DATED_SUFFIX
      TIERS = [*Providers::Litellm::TIERS.values, "fast"].freeze
      TIERED_FIELD = /\A(?<context>above_context_)?(?:(?<tier>#{TIERS.join('|')})_)?(?<dimension>.+)\z/
      SECTIONS = {
        notes: "Scraper notes",
        difference: "Values that differ by more than 1% (official kept)",
        model: "LiteLLM-only models of fully scraped providers",
        held: "LiteLLM-only models models.dev prices differently (not written)",
        unconfirmed: "LiteLLM-only models models.dev does not list (not written)",
        field: "LiteLLM-only fields on covered models",
        unknown: "Unknown LiteLLM fields",
        unrepresentable: "Not representable",
        stale: "Stale acknowledgements"
      }.freeze
      ISSUE_SECTIONS = SECTIONS.keys - %i[unknown unrepresentable]
      SECTION_LINES = {
        notes: :note_lines, stale: :stale_lines, difference: :difference_lines, model: :provider_lines,
        unconfirmed: :provider_lines, field: :field_gap_lines, unknown: :unknown_lines
      }.freeze
      Finding = Data.define(:section, :model, :field, :detail)

      class Error < StandardError; end

      class << self
        def run(
          report_path:,
          issue_path:,
          registry_path: REGISTRY_PATH,
          acknowledged_path: ACKNOWLEDGED_PATH,
          notes_path: nil,
          fetcher: Fetcher.new,
          sha: nil
        )
          sha ||= main_commit
          check = new(registry: JSON.parse(File.read(registry_path)),
                      catalogue: JSON.parse(fetcher.get(format(Providers::Litellm::PRICES_URL, sha)).body),
                      models_dev: JSON.parse(fetcher.get(Providers::Litellm::MODELS_DEV_URL).body),
                      acknowledged: YAML.safe_load_file(acknowledged_path) || {},
                      notes: notes_path && File.exist?(notes_path) ? File.readlines(notes_path, chomp: true) : [])
          File.write(report_path, check.report(sha))
          File.write(issue_path, check.findings(ISSUE_SECTIONS))
        end

        private

        def main_commit
          IO.popen(["git", "ls-remote", REPOSITORY, "refs/heads/main"], &:read)[/\A\h{40}/] or
            raise Error, "LiteLLM main commit not found"
        end
      end

      def initialize(registry:, catalogue:, models_dev: {}, acknowledged: {}, notes: [], today: Date.today)
        comparison = Comparison.new(registry, catalogue, today).call(models_dev)
        @findings = comparison.findings
        @counts = comparison.counts
        @acknowledged = acknowledged
        @notes = notes
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

      def findings(sections = SECTIONS.keys)
        open = reported.reject { |finding| acknowledgement(finding) }.group_by(&:section)
        SECTIONS.slice(*sections).filter_map do |section, title|
          lines = section_lines(section, open.fetch(section, []))
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

      def reported
        @findings.reject do |finding|
          provider = finding.model.split("/").first
          COUNTS_ONLY.include?(provider) || UNCAPTURED[provider]&.match?(finding.model)
        end
      end

      def acknowledgement(finding)
        key = finding.field ? "#{finding.model}.#{finding.field}" : finding.model
        key if @acknowledged.key?(key)
      end

      def section_lines(section, found) = send(SECTION_LINES.fetch(section, :detail_lines), found)

      def note_lines(_found) = @notes

      def stale_lines(_found)
        stale = @acknowledged.keys - reported.filter_map { |finding| acknowledgement(finding) }
        stale.map { |key| "- `#{key}` no longer matches a finding" }
      end

      def difference_lines(found)
        return [] if found.empty?

        rows = found.sort_by { |finding| [finding.model, finding.field] }.map do |finding|
          ours, theirs = finding.detail
          change = ours.is_a?(Numeric) && !ours.zero? ? format("%+.0f%%", (theirs - ours) * 100.0 / ours) : ""
          "| #{finding.model} | `#{finding.field}` | #{ours.to_json} | #{theirs.to_json} | #{change} |"
        end
        ["| model | field | ours | LiteLLM | change |", "|---|---|---|---|---|", *rows]
      end

      def field_gap_lines(found)
        gaps = found.group_by(&:model).transform_values do |list|
          list.map { |finding| "`#{finding.field}`#{" (x#{finding.detail})" if finding.detail}" }.sort
        end
        gaps.group_by(&:last).map { |list, models| "- #{list.join(', ')}: #{models.map(&:first).sort.join(', ')}" }.sort
      end

      def unknown_lines(found)
        found.group_by(&:field).sort.map do |name, list|
          "- `#{name}` (#{list.size}): #{list.map(&:model).first(3).join(', ')}"
        end
      end

      def provider_lines(found) = grouped(found) { |finding| finding.model.split("/").first }

      def detail_lines(found) = grouped(found, &:detail)

      def grouped(found, &)
        found.group_by(&).sort.map { |label, list| "- #{label}: #{list.map(&:model).sort.join(', ')}" }
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  LlmCostTracker::Pricing::Scrape::CrossCheck.run(
    report_path: ARGV.fetch(0),
    issue_path: ARGV.fetch(1),
    notes_path: ARGV[2],
    sha: ENV["LITELLM_SHA"].presence
  )
end
