# frozen_string_literal: true

require "json"

require_relative "../../lib/llm_cost_tracker"

module LlmCostTracker
  module Pricing::Scrape
    class PrSummary
      CHURN_PROVIDERS = %w[openrouter].freeze
      LISTED = 30
      FIELDS_PER_MODEL = 3
      LEAD_FIELDS = ["input", "output", "cache_read_input", Pricing::Registry::CONTEXT_THRESHOLD_KEY].freeze
      VERDICTS = { red: "🛑 Do not merge yet", review: "⚠️ Review before merging", safe: "✅ Safe to merge" }.freeze

      def self.run(before_path:, after_path:, log_path:, summary_path:, title_path:)
        summary = new(
          before: JSON.parse(File.read(before_path)),
          after: JSON.parse(File.read(after_path)),
          log: File.exist?(log_path) ? File.read(log_path) : ""
        )
        File.write(summary_path, summary.markdown)
        File.write(title_path, summary.title)
      end

      def initialize(before:, after:, log: "")
        @before = before.fetch("models", {})
        @after = after.fetch("models", {})
        @failed = log.scan(/^\[([a-z_-]+)\] FAILED/).flatten.uniq
        @changes = Pricing::Sync::RegistryDiff.call(@before, @after)
        charges = Pricing::Sync::RegistryDiff.nested(before.fetch("service_charges", {}),
                                                     after.fetch("service_charges", {}))
        @charges = charges.flat_map do |provider, fields|
          fields.map { |field, values| ["#{provider}.#{field}", values] }
        end
        guarded = charges.any? ? @changes.merge("service_charges" => charges) : @changes
        @red_flags = Pricing::Sync::SnapshotGuard.call(current: before, remote: after, changes: guarded)
        @unlisted = after.dig("metadata", "absent_since").to_h.keys - before.dig("metadata", "absent_since").to_h.keys
      end

      def verdict
        return :red if @red_flags.any?
        return :review if official? || @failed.any?

        :safe
      end

      def title
        "Refresh prices: #{VERDICTS.fetch(verdict).split(' ', 2).last.downcase}"
      end

      def markdown
        [
          "## #{VERDICTS.fetch(verdict)}",
          reasons.map { |reason| "- #{reason}" }.join("\n"),
          table,
          section("Red flags", @red_flags.map { |flag| "`#{flag}`" }),
          section("Official price changes", official_changes),
          section("New official models", new_models(litellm: false)),
          section("New models priced from LiteLLM", new_models(litellm: true)),
          section("Removed official models", official(removed).map { |key| "`#{key}`" })
        ].compact.join("\n\n") << "\n"
      end

      private

      def reasons
        lines = []
        if verdict == :red
          lines << "Red flags below look like parse errors; users' `prices:refresh` refuses a snapshot with them."
        end
        lines << "Official prices changed: check them against the provider's pricing page." if official?
        @failed.each { |provider| lines << "`#{provider}` failed to scrape; its prices are not in this PR." }
        lines << "Only #{CHURN_PROVIDERS.join(', ')} prices moved, the routine daily churn." if lines.empty?
        return lines if @unlisted.empty?

        lines << "#{@unlisted.size} models are no longer listed upstream; they drop out after 90 days."
      end

      def table
        providers = (@changes.keys + added + removed + @unlisted).map { |key| key.split("/").first }.uniq.sort
        return if providers.empty?

        rows = providers.map do |provider|
          counts = [updated, added, removed, @unlisted].map do |keys|
            keys.count { |key| key.start_with?("#{provider}/") }
          end
          "| #{provider} | #{counts.join(' | ')} |"
        end
        ["| Provider | New prices | Added | Removed | No longer listed |", "|---|---|---|---|---|", *rows].join("\n")
      end

      def section(title, lines)
        return if lines.empty?

        shown = lines.first(LISTED).map { |line| "- #{line}" }
        shown << "- and #{lines.size - LISTED} more in the diff below" if lines.size > LISTED
        "### #{title}\n\n#{shown.join("\n")}"
      end

      def official?
        official_changes.any? || official(added).any? || official(removed).any?
      end

      def official_changes
        @official_changes ||= official(updated).map do |key|
          fields = @changes.fetch(key).sort_by { |field, _| [field.length, field] }
                           .map { |field, values| change(field, values) }
          more = fields.size - FIELDS_PER_MODEL
          "`#{key}`: #{fields.first(FIELDS_PER_MODEL).join(', ')}#{", #{more} more fields" if more.positive?}"
        end + @charges.reject { |name, _| churn?(name) }.map { |name, values| "`#{name}`: #{change(nil, values)}" }
      end

      def change(field, values)
        from, to = values.values_at("from", "to")
        delta = [from, to].all?(Numeric) && from.positive? ? format(" (%+.0f%%)", (to - from) * 100 / from) : ""
        "#{"#{field} " if field}#{shown(from)} → #{shown(to)}#{delta}"
      end

      def new_models(litellm:)
        official(added).select { |key| (@after[key]["_source"] == "litellm") == litellm }
                       .map { |key| "`#{key}`: #{prices(@after[key])}" }
      end

      def prices(entry)
        lead = entry.slice(*LEAD_FIELDS)
        shown = lead.any? ? lead : entry.reject { |field, _| field.start_with?("_") }.first(FIELDS_PER_MODEL)
        shown.map { |field, value| "#{field} #{value}" }.join(", ")
      end

      def shown(value)
        return "none" if value.nil?

        value.is_a?(BigDecimal) ? value.to_s("F") : value.to_s
      end

      def official(keys) = keys.reject { |key| churn?(key) }
      def churn?(key) = CHURN_PROVIDERS.include?(key.split(%r{[/.]}).first)
      def added = @after.keys - @before.keys
      def removed = @before.keys - @after.keys
      def updated = @changes.keys & @before.keys & @after.keys
    end
  end
end

if $PROGRAM_NAME == __FILE__
  LlmCostTracker::Pricing::Scrape::PrSummary.run(
    before_path: ARGV.fetch(0),
    after_path: ARGV.fetch(1),
    log_path: ARGV.fetch(2),
    summary_path: ARGV.fetch(3),
    title_path: ARGV.fetch(4)
  )
end
