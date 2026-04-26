# frozen_string_literal: true

require "date"
require "json"
require "rubygems"

require_relative "price_sync/fetcher"
require_relative "price_sync/registry_diff"
require_relative "price_sync/registry_loader"
require_relative "price_sync/registry_writer"

module LlmCostTracker
  module PriceSync
    DEFAULT_OUTPUT_PATH = "config/llm_cost_tracker_prices.yml"
    DEFAULT_REMOTE_URL =
      "https://raw.githubusercontent.com/sergey-homenko/llm_cost_tracker/main/lib/llm_cost_tracker/prices.json"
    SUPPORTED_SCHEMA_VERSION = 1

    RefreshResult = Data.define(:path, :source_url, :source_version, :changes, :written, :not_modified)
    CheckResult = Data.define(:path, :source_url, :source_version, :changes, :up_to_date)

    class << self
      def configured_output_path(env: ENV, config: LlmCostTracker.configuration)
        output = env["OUTPUT"].to_s.strip
        return output unless output.empty?

        prices_file = config.prices_file
        return prices_file.to_s if prices_file

        default_output_path
      end

      def configured_remote_url(env: ENV)
        url = env["URL"].to_s.strip
        url.empty? ? DEFAULT_REMOTE_URL : url
      end

      def refresh(path: DEFAULT_OUTPUT_PATH, url: DEFAULT_REMOTE_URL, preview: false, fetcher: Fetcher.new,
                  today: Date.today)
        current = load_current_registry(path)
        response = fetcher.get(url, etag: current.dig("metadata", "source_version"))

        if response.not_modified
          return refresh_result(path, url, response, current, current, written: false, not_modified: true)
        end

        remote = normalize_remote_registry(response.body, url: url, response: response, today: today)
        RegistryWriter.new.call(path: path, registry: remote) unless preview
        refresh_result(path, url, response, current, remote, written: !preview, not_modified: false)
      end

      def check(path: DEFAULT_OUTPUT_PATH, url: DEFAULT_REMOTE_URL, fetcher: Fetcher.new, today: Date.today)
        current = load_current_registry(path)
        response = fetcher.get(url, etag: current.dig("metadata", "source_version"))

        if response.not_modified
          return CheckResult.new(
            path: path,
            source_url: url,
            source_version: response.source_version,
            changes: {},
            up_to_date: true
          )
        end

        remote = normalize_remote_registry(response.body, url: url, response: response, today: today)
        changes = RegistryDiff.call(current.fetch("models", {}), remote.fetch("models", {}))

        CheckResult.new(
          path: path,
          source_url: url,
          source_version: response.source_version,
          changes: changes,
          up_to_date: changes.empty?
        )
      end

      private

      def default_output_path
        if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          Rails.root.join(DEFAULT_OUTPUT_PATH).to_s
        else
          DEFAULT_OUTPUT_PATH
        end
      end

      def load_current_registry(path)
        RegistryLoader.new.call(path: path, seed_path: PriceRegistry::DEFAULT_PRICES_PATH)
      end

      def normalize_remote_registry(body, url:, response:, today:)
        registry = parse_registry(body)
        metadata = registry.fetch("metadata", {})
        raise Error, "remote pricing metadata must be a hash" unless metadata.is_a?(Hash)

        schema_version = Integer(metadata.fetch("schema_version", 1))
        if schema_version > SUPPORTED_SCHEMA_VERSION
          raise Error, "remote pricing schema_version=#{schema_version} requires a newer llm_cost_tracker"
        end

        min_gem_version = metadata["min_gem_version"]
        if min_gem_version && Gem::Version.new(min_gem_version) > Gem::Version.new(LlmCostTracker::VERSION)
          raise Error, "remote pricing snapshot requires llm_cost_tracker >= #{min_gem_version}"
        end

        models = registry.fetch("models", {})
        PriceRegistry.normalize_price_table(models)

        registry.merge(
          "metadata" => metadata.merge(
            "schema_version" => schema_version,
            "updated_at" => metadata["updated_at"] || today.iso8601,
            "source_url" => url,
            "source_version" => response.source_version
          ),
          "models" => models
        )
      rescue ArgumentError, TypeError => e
        raise Error, "Unable to load remote pricing snapshot: #{e.message}"
      end

      def parse_registry(body)
        registry = JSON.parse(body.to_s)
        raise Error, "remote pricing snapshot must be a JSON object" unless registry.is_a?(Hash)

        registry
      rescue JSON::ParserError => e
        raise Error, "Unable to parse remote pricing snapshot: #{e.message}"
      end

      def refresh_result(path, url, response, current, remote, written:, not_modified:)
        RefreshResult.new(
          path: path,
          source_url: url,
          source_version: response.source_version,
          changes: RegistryDiff.call(current.fetch("models", {}), remote.fetch("models", {})),
          written: written,
          not_modified: not_modified
        )
      end
    end
  end
end
