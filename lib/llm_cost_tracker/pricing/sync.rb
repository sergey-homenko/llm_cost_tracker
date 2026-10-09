# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "date"

require_relative "registry"
require_relative "sync/fetcher"
require_relative "sync/registry_diff"
require_relative "sync/registry_writer"
require_relative "sync/remote_snapshot"
require_relative "sync/snapshot_guard"

module LlmCostTracker
  module Pricing
    module Sync
      DEFAULT_OUTPUT_PATH = "config/llm_cost_tracker_prices.yml"
      DEFAULT_REMOTE_URL =
        "https://raw.githubusercontent.com/sergey-homenko/llm_cost_tracker/main/lib/llm_cost_tracker/prices.json"
      SUPPORTED_SCHEMA_VERSION = 1

      RefreshResult = Data.define(:path, :source_url, :source_version, :changes, :suspicious, :written, :not_modified)
      CheckResult = Data.define(:path, :source_url, :source_version, :changes, :suspicious, :up_to_date)

      class << self
        def configured_output_path(env: ENV, config: LlmCostTracker.configuration)
          output = env["OUTPUT"].to_s.strip.presence
          return output if output

          prices_file = config.pricing.file
          return prices_file.to_s if prices_file

          Rails.root.join(DEFAULT_OUTPUT_PATH).to_s
        end

        def configured_remote_url(env: ENV)
          env["URL"].to_s.strip.presence || DEFAULT_REMOTE_URL
        end

        def refresh(path: DEFAULT_OUTPUT_PATH,
                    url: DEFAULT_REMOTE_URL,
                    preview: false,
                    force: false,
                    fetcher: Fetcher.new,
                    today: Date.today)
          response, remote, changes, suspicious = compare(path, url, fetcher, today)
          written = !preview && !response.not_modified
          if written
            refuse_suspicious_snapshot!(path, suspicious) unless force || suspicious.empty?
            RegistryWriter.new.call(path: path, registry: remote)
            Pricing::Registry.reset!
          end
          RefreshResult.new(
            path: path,
            source_url: Fetcher.scrub_url(url),
            source_version: response.source_version,
            changes: changes,
            suspicious: suspicious,
            written: written,
            not_modified: response.not_modified
          )
        end

        def check(path: DEFAULT_OUTPUT_PATH, url: DEFAULT_REMOTE_URL, fetcher: Fetcher.new, today: Date.today)
          response, _remote, changes, suspicious = compare(path, url, fetcher, today)
          CheckResult.new(
            path: path,
            source_url: Fetcher.scrub_url(url),
            source_version: response.source_version,
            changes: changes,
            suspicious: suspicious,
            up_to_date: changes.empty? && suspicious.empty?
          )
        end

        private

        def compare(path, url, fetcher, today)
          current = load_registry(path)
          response = fetcher.get(url, etag: current.dig("metadata", "source_version"))
          return [response, nil, {}, []] if response.not_modified

          snapshot = RemoteSnapshot.new(response.body)
          remote = RegistryWriter.new.merge_with_existing(
            path: path, registry: snapshot.registry(url: url, source_version: response.source_version, today: today)
          )
          changes = registry_changes(current, remote)
          [response, remote, changes, SnapshotGuard.call(current: current, remote: remote, changes: changes)]
        end

        def load_registry(path)
          return {} unless File.exist?(path)

          YAML.safe_load_file(path, aliases: false) || {}
        rescue Psych::Exception, ArgumentError, TypeError => e
          raise Error, "Unable to load pricing registry #{path.inspect}: #{e.message}"
        end

        def refuse_suspicious_snapshot!(path, suspicious)
          listed = suspicious.first(20).map { |finding| "\n  - #{finding}" }.join
          raise Error,
                "Refusing to write pricing file #{path}: the remote snapshot has #{suspicious.size} " \
                "suspicious price change(s):#{listed}\n" \
                "Review them with llm_cost_tracker:prices:check, " \
                "then refresh with FORCE=1 (force: true) to accept them."
        end

        def registry_changes(current, remote)
          model_changes = RegistryDiff.call(current.fetch("models", {}), remote.fetch("models", {}))
          charge_changes = RegistryDiff.nested(
            current.fetch("service_charges", {}),
            remote.fetch("service_charges", {})
          )
          return model_changes if charge_changes.empty?

          model_changes.merge("service_charges" => charge_changes)
        end
      end
    end
  end
end
