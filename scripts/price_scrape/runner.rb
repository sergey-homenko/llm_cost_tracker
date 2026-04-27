# frozen_string_literal: true

require_relative "../../lib/llm_cost_tracker"
require_relative "fetcher"
require_relative "providers/anthropic"
require_relative "providers/gemini"
require_relative "providers/openai"
require_relative "orchestrator"

module LlmCostTracker
  module PriceScrape
    class Runner
      PROVIDERS = {
        "anthropic" => Providers::Anthropic,
        "gemini" => Providers::Gemini,
        "openai" => Providers::Openai
      }.freeze

      DEFAULT_REGISTRY_PATH = File.expand_path("../../lib/llm_cost_tracker/prices.json", __dir__)

      ProviderRun = Data.define(:name, :scraped, :orchestrator, :error)

      class Error < StandardError; end

      DEFAULT_ORCHESTRATOR_FACTORY = ->(dry_run:) { Orchestrator.new(dry_run: dry_run) }

      def initialize(fetcher: Fetcher.new, orchestrator_factory: DEFAULT_ORCHESTRATOR_FACTORY, io: $stdout)
        @fetcher = fetcher
        @orchestrator_factory = orchestrator_factory
        @io = io
      end

      def call(providers:, registry_path: DEFAULT_REGISTRY_PATH, dry_run: false)
        unknown = providers - PROVIDERS.keys
        raise Error, "unknown providers: #{unknown.inspect}" if unknown.any?

        runs = providers.map do |name|
          run_provider(name: name, registry_path: registry_path, dry_run: dry_run)
        end
        log_summary(runs, dry_run: dry_run)
        failures = runs.select(&:error)
        raise Error, "provider scrape failures: #{failures.map(&:name).join(', ')}" if failures.any?

        runs
      end

      private

      def run_provider(name:, registry_path:, dry_run:)
        provider_class = PROVIDERS.fetch(name)

        @io.puts "[#{name}] fetching #{provider_class::SOURCE_URL}"
        response = @fetcher.get(provider_class::SOURCE_URL)
        @io.puts "[#{name}] HTTP #{response.status} (#{response.body.bytesize} bytes, #{response.elapsed_ms}ms)"

        scraped = provider_class.new.call(
          html: response.body,
          source_url: response.url,
          scraped_at: response.fetched_at
        )
        @io.puts "[#{name}] parsed #{scraped.models.size} models (deprecated: #{scraped.deprecated_models.size})"

        orchestrator_result = @orchestrator_factory.call(dry_run: dry_run).call(
          provider_result: scraped,
          registry_path: registry_path
        )
        log_provider_result(name, orchestrator_result, dry_run: dry_run)

        ProviderRun.new(name: name, scraped: scraped, orchestrator: orchestrator_result, error: nil)
      rescue StandardError => e
        @io.puts "[#{name}] FAILED: #{e.class}: #{e.message}"
        e.backtrace.first(5).each { |line| @io.puts "[#{name}]   #{line}" }
        ProviderRun.new(name: name, scraped: nil, orchestrator: nil, error: e)
      end

      def log_provider_result(name, result, dry_run:)
        prefix = "[#{name}]"
        unless result.changed?
          @io.puts "#{prefix} no changes"
          return
        end

        @io.puts "#{prefix} added=#{result.added.size} removed=#{result.removed.size} updated=#{result.updated.size} " \
                 "written=#{result.written} dry_run=#{dry_run}"
      end

      def log_summary(runs, dry_run:)
        failures, successes = runs.partition(&:error)
        added = successes.sum { |run| run.orchestrator.added.size }
        removed = successes.sum { |run| run.orchestrator.removed.size }
        updated = successes.sum { |run| run.orchestrator.updated.size }
        wrote = successes.count { |run| run.orchestrator.written }
        @io.puts(
          "[summary] providers=#{runs.size} ok=#{successes.size} failed=#{failures.size} " \
          "wrote=#{wrote} added=#{added} removed=#{removed} updated=#{updated} dry_run=#{dry_run}"
        )
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  providers = (ENV["PROVIDERS"] || "anthropic").split(",").map(&:strip).reject(&:empty?)
  dry_run = ENV["DRY_RUN"] == "1"
  LlmCostTracker::PriceScrape::Runner.new.call(providers: providers, dry_run: dry_run)
end
