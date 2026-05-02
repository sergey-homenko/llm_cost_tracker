# frozen_string_literal: true

require_relative "../../lib/llm_cost_tracker"
require_relative "fetcher"
require_relative "providers/anthropic"
require_relative "providers/gemini"
require_relative "providers/groq"
require_relative "providers/openai"
require_relative "orchestrator"

module LlmCostTracker
  module Pricing::Scrape
    class Runner
      PROVIDERS = {
        "anthropic" => Providers::Anthropic,
        "gemini" => Providers::Gemini,
        "groq" => Providers::Groq,
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

        responses = fetch_provider_responses(name, provider_class)
        primary_response = responses.fetch(provider_class::SOURCE_URL)

        scraped = provider_class.new.call(
          html: provider_html(responses),
          source_url: primary_response.url,
          scraped_at: primary_response.fetched_at
        )
        @io.puts "[#{name}] parsed #{scraped.models.size} models (deprecated: #{scraped.deprecated_models.size})"

        orchestrator_result = @orchestrator_factory.call(dry_run: dry_run).call(
          provider: name,
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

      def fetch_provider_responses(name, provider_class)
        source_urls(provider_class).each_with_object({}) do |url, responses|
          @io.puts "[#{name}] fetching #{url}"
          response = @fetcher.get(url)
          @io.puts "[#{name}] HTTP #{response.status} (#{response.body.bytesize} bytes, #{response.elapsed_ms}ms)"
          responses[url] = response
        end
      end

      def provider_html(responses)
        return responses.values.first.body if responses.size == 1

        responses.transform_values(&:body)
      end

      def source_urls(provider_class)
        return provider_class::SOURCE_URLS if provider_class.const_defined?(:SOURCE_URLS)

        [provider_class::SOURCE_URL]
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
  providers = (ENV["PROVIDERS"] || LlmCostTracker::Pricing::Scrape::Runner::PROVIDERS.keys.join(","))
              .split(",")
              .map(&:strip)
              .select(&:present?)
  dry_run = ENV["DRY_RUN"] == "1"
  LlmCostTracker::Pricing::Scrape::Runner.new.call(providers: providers, dry_run: dry_run)
end
