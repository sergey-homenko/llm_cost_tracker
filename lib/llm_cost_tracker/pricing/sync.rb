# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "date"
require "json"
require "rubygems"

require_relative "registry"
require_relative "sync/fetcher"
require_relative "sync/registry_diff"
require_relative "sync/registry_writer"

module LlmCostTracker
  module Pricing
    module Sync
      DEFAULT_OUTPUT_PATH = "config/llm_cost_tracker_prices.yml"
      DEFAULT_REMOTE_URL =
        "https://raw.githubusercontent.com/sergey-homenko/llm_cost_tracker/main/lib/llm_cost_tracker/prices.json"
      SUPPORTED_SCHEMA_VERSION = 1

      RefreshResult = Data.define(:path, :source_url, :source_version, :changes, :written, :not_modified)
      CheckResult = Data.define(:path, :source_url, :source_version, :changes, :up_to_date)

      class << self
        def configured_output_path(env: ENV, config: LlmCostTracker.configuration)
          output = env["OUTPUT"].to_s.strip.presence
          return output if output

          prices_file = config.prices_file
          return prices_file.to_s if prices_file

          Rails.root.join(DEFAULT_OUTPUT_PATH).to_s
        end

        def configured_remote_url(env: ENV)
          env["URL"].to_s.strip.presence || DEFAULT_REMOTE_URL
        end

        def refresh(path: DEFAULT_OUTPUT_PATH, url: DEFAULT_REMOTE_URL, preview: false, fetcher: Fetcher.new,
                    today: Date.today)
          current = load_registry(path)
          response = fetcher.get(url, etag: current.dig("metadata", "source_version"))

          if response.not_modified
            return refresh_result(
              path: path,
              url: url,
              response: response,
              current: current,
              remote: current,
              written: false,
              not_modified: true
            )
          end

          remote = normalize_remote_registry(response.body, url: url, response: response, today: today)
          unless preview
            RegistryWriter.new.call(path: path, registry: remote)
            Pricing::Registry.reset!
          end
          refresh_result(
            path: path,
            url: url,
            response: response,
            current: current,
            remote: remote,
            written: !preview,
            not_modified: false
          )
        end

        def check(path: DEFAULT_OUTPUT_PATH, url: DEFAULT_REMOTE_URL, fetcher: Fetcher.new, today: Date.today)
          current = load_registry(path)
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
          changes = registry_changes(current, remote)

          CheckResult.new(
            path: path,
            source_url: url,
            source_version: response.source_version,
            changes: changes,
            up_to_date: changes.empty?
          )
        end

        private

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

          raw_models = registry.fetch("models", {})
          models = Registry.normalize_price_entries(raw_models, context: "remote pricing snapshot")
                           .each_with_object({}) do |(model, prices), normalized|
            model_metadata = (raw_models[model] || {}).slice(*Registry::METADATA_KEYS)
            normalized[model] = model_metadata.merge(prices)
          end
          service_charges = registry["service_charges"]
          Registry.rates_from_registry(registry, context: "remote pricing snapshot") if service_charges

          normalized = {
            "metadata" => metadata.merge(
              "schema_version" => schema_version,
              "updated_at" => metadata["updated_at"] || today.iso8601,
              "source_url" => url,
              "source_version" => response.source_version
            ),
            "models" => models
          }
          normalized["service_charges"] = service_charges if service_charges.present?
          normalized
        rescue ArgumentError, TypeError => e
          raise Error, "Unable to load remote pricing snapshot: #{e.message}"
        end

        def load_registry(path)
          return {} unless File.exist?(path)

          YAML.safe_load_file(path, aliases: false) || {}
        rescue Psych::Exception, ArgumentError, TypeError => e
          raise Error, "Unable to load pricing registry #{path.inspect}: #{e.message}"
        end

        def parse_registry(body)
          registry = JSON.parse(body.to_s)
          raise Error, "remote pricing snapshot must be a JSON object" unless registry.is_a?(Hash)

          registry
        rescue JSON::ParserError => e
          raise Error, "Unable to parse remote pricing snapshot: #{e.message}"
        end

        def refresh_result(path:, url:, response:, current:, remote:, written:, not_modified:)
          RefreshResult.new(
            path: path,
            source_url: url,
            source_version: response.source_version,
            changes: registry_changes(current, remote),
            written: written,
            not_modified: not_modified
          )
        end

        def registry_changes(current, remote)
          model_changes = RegistryDiff.call(current.fetch("models", {}), remote.fetch("models", {}))
          charge_changes = service_charges_diff(
            current.fetch("service_charges", {}),
            remote.fetch("service_charges", {})
          )
          return model_changes if charge_changes.empty?

          model_changes.merge("service_charges" => charge_changes)
        end

        def service_charges_diff(current, remote)
          (current.keys | remote.keys).sort.each_with_object({}) do |provider, changes|
            current_rates = (current[provider] || {}).transform_keys(&:to_s)
            remote_rates = (remote[provider] || {}).transform_keys(&:to_s)
            (current_rates.keys | remote_rates.keys).sort.each_with_object(changes) do |component, _|
              from = current_rates[component]
              to = remote_rates[component]
              next if from == to

              changes[provider] ||= {}
              changes[provider][component] = { "from" => from, "to" => to }
            end
          end
        end
      end
    end
  end
end
