# frozen_string_literal: true

require_relative "../../lib/llm_cost_tracker"
require_relative "fetcher"
require_relative "providers/anthropic"
require_relative "providers/cohere"
require_relative "providers/deepseek"
require_relative "providers/gemini"
require_relative "providers/groq"
require_relative "providers/mistral"
require_relative "providers/openai"
require_relative "providers/openrouter"
require_relative "providers/xai"
require_relative "orchestrator"

module LlmCostTracker
  module Pricing::Scrape
    class Runner
      PROVIDERS = {
        "anthropic" => Providers::Anthropic,
        "cohere" => Providers::Cohere,
        "deepseek" => Providers::Deepseek,
        "gemini" => Providers::Gemini,
        "groq" => Providers::Groq,
        "mistral" => Providers::Mistral,
        "openai" => Providers::Openai,
        "openrouter" => Providers::Openrouter,
        "xai" => Providers::Xai
      }.freeze

      DEFAULT_REGISTRY_PATH = File.expand_path("../../lib/llm_cost_tracker/prices.json", __dir__)
      CHANGES = %i[added removed updated service_charges_updated].freeze

      ProviderRun = Data.define(:name, :scraped, :orchestrator, :error)

      class Error < StandardError; end

      DEFAULT_ORCHESTRATOR_FACTORY = ->(dry_run:) { Orchestrator.new(dry_run: dry_run) }

      def initialize(
        fetcher: Fetcher.new,
        orchestrator_factory: DEFAULT_ORCHESTRATOR_FACTORY,
        io: $stdout,
        litellm_sha: nil
      )
        @fetcher = fetcher
        @orchestrator_factory = orchestrator_factory
        @io = io
        @litellm_sha = litellm_sha
      end

      def call(providers:, registry_path: DEFAULT_REGISTRY_PATH, dry_run: false, notes_path: nil)
        unknown = providers - PROVIDERS.keys
        raise Error, "unknown providers: #{unknown.inspect}" if unknown.any?

        @responses = {}
        runs = providers.map do |name|
          run_provider(name: name, registry_path: registry_path, dry_run: dry_run)
        end
        log_summary(runs, dry_run: dry_run)
        write_notes(runs, notes_path) if notes_path
        failures = runs.select(&:error)
        raise Error, "provider scrape failures: #{failures.map(&:name).join(', ')}" if failures.any?

        runs
      end

      private

      def run_provider(name:, registry_path:, dry_run:)
        scraped = scrape(name)
        orchestrator_result = @orchestrator_factory.call(dry_run: dry_run).call(
          provider: name,
          provider_result: scraped,
          registry_path: registry_path,
          source_urls: canonical_source_urls
        )
        log_notes(name, orchestrator_result.notes)
        log_provider_result(name, orchestrator_result, dry_run: dry_run)
        ProviderRun.new(name: name, scraped: scraped, orchestrator: orchestrator_result, error: nil)
      rescue StandardError => e
        @io.puts "[#{name}] FAILED: #{e.class}: #{e.message}"
        e.backtrace.first(5).each { |line| @io.puts "[#{name}]   #{line}" }
        ProviderRun.new(name: name, scraped: nil, orchestrator: nil, error: e)
      end

      def scrape(name)
        provider_class = PROVIDERS.fetch(name)
        responses = fetch_provider_responses(name, provider_class)
        primary_response = responses.fetch(provider_class.source_url)
        scraped = provider_class.new.call(
          html: provider_html(responses),
          source_url: primary_response.url,
          scraped_at: primary_response.fetched_at
        )
        @io.puts "[#{name}] parsed #{scraped.models.size} models (deprecated: #{scraped.deprecated_models.size})"
        log_notes(name, scraped.notes)
        scraped
      end

      def log_notes(name, notes)
        notes.each { |note| @io.puts "[#{name}] #{note}" }
      end

      def write_notes(runs, path)
        notes = runs.reject(&:error).flat_map { |run| run.scraped.notes }
        File.write(path, notes.map { |note| "#{note}\n" }.join)
      end

      def fetch_provider_responses(name, provider_class)
        responses = source_urls(provider_class).to_h { |url| [url, fetch(name, url)] }.compact
        followups = provider_class.followup_urls(responses.transform_values(&:body))
        responses.merge(followups.to_h { |url| [url, fetch(name, url)] })
      end

      def fetch(name, url)
        @responses[url] ||= begin
          pinned = url == Providers::Litellm::SOURCE_URL && @litellm_sha
          target = pinned ? format(Providers::Litellm::PRICES_URL, @litellm_sha) : url
          @io.puts "[#{name}] fetching #{target}"
          response = @fetcher.get(target)
          @io.puts "[#{name}] redirected to #{response.url}" if response.url != target
          @io.puts "[#{name}] HTTP #{response.status} (#{response.body.bytesize} bytes, #{response.elapsed_ms}ms)"
          response
        end
      rescue Fetcher::Error => e
        raise unless url == Providers::Litellm::MODELS_DEV_URL

        @io.puts "[#{name}] skipped #{url}: #{e.message}"
        nil
      end

      def provider_html(responses)
        return responses.values.first.body if responses.size == 1

        responses.transform_values(&:body)
      end

      def source_urls(provider_class)
        return provider_class::SOURCE_URLS if provider_class.const_defined?(:SOURCE_URLS)

        [provider_class.source_url]
      end

      def canonical_source_urls
        PROVIDERS.values.flat_map { |provider_class| source_urls(provider_class) }.uniq
      end

      def log_provider_result(name, result, dry_run:)
        return @io.puts("[#{name}] no changes") unless result.changed?

        counts = change_counts([result], [*CHANGES, :absent])
        @io.puts "[#{name}] #{counts} written=#{result.written} dry_run=#{dry_run}"
      end

      def log_summary(runs, dry_run:)
        failures, successes = runs.partition(&:error)
        results = successes.map(&:orchestrator)
        @io.puts(
          "[summary] providers=#{runs.size} ok=#{successes.size} failed=#{failures.size} " \
          "wrote=#{results.count(&:written)} #{change_counts(results, CHANGES)} dry_run=#{dry_run}"
        )
      end

      def change_counts(results, changes)
        changes.map { |change| "#{change}=#{results.sum { |result| result.public_send(change).size }}" }.join(" ")
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  require "logger"
  require "active_support/tagged_logging"
  Rails.logger = ActiveSupport::TaggedLogging.new(Logger.new($stderr))

  providers = (ENV["PROVIDERS"] || LlmCostTracker::Pricing::Scrape::Runner::PROVIDERS.keys.join(","))
              .split(",")
              .map(&:strip)
              .select(&:present?)
  dry_run = ENV["DRY_RUN"] == "1"
  LlmCostTracker::Pricing::Scrape::Runner.new(litellm_sha: ENV["LITELLM_SHA"].presence).call(
    providers: providers,
    dry_run: dry_run,
    notes_path: ENV["NOTES_PATH"].presence
  )
end
