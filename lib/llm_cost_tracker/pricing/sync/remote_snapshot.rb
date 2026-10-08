# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "json"
require "rubygems"

module LlmCostTracker
  module Pricing
    module Sync
      class RemoteSnapshot
        CONTEXT = "remote pricing snapshot"

        def initialize(body)
          @registry = parse(body)
          @metadata = @registry.fetch("metadata", {})
          raise Error, "remote pricing metadata must be a hash" unless @metadata.is_a?(Hash)
        end

        def registry(url:, source_version:, today:)
          check_compatibility!
          models = models_with_metadata
          Registry.rates_from_registry(@registry, context: CONTEXT) if service_charges
          {
            "metadata" => @metadata.merge(
              "schema_version" => schema_version,
              "updated_at" => @metadata["updated_at"] || today.iso8601,
              "source_url" => Redaction.text(url),
              "source_version" => source_version
            ),
            "models" => models,
            "service_charges" => service_charges.presence
          }.compact
        rescue ArgumentError, TypeError => e
          raise Error, "Unable to load remote pricing snapshot: #{e.message}"
        end

        private

        def parse(body)
          registry = JSON.parse(body.to_s)
          raise Error, "remote pricing snapshot must be a JSON object" unless registry.is_a?(Hash)

          registry
        rescue JSON::ParserError => e
          raise Error, "Unable to parse remote pricing snapshot: #{e.message}"
        end

        def check_compatibility!
          if schema_version > SUPPORTED_SCHEMA_VERSION
            raise Error, "remote pricing schema_version=#{schema_version} requires a newer llm_cost_tracker"
          end

          min_gem_version = @metadata["min_gem_version"]
          return unless min_gem_version && Gem::Version.new(min_gem_version) > Gem::Version.new(LlmCostTracker::VERSION)

          raise Error, "remote pricing snapshot requires llm_cost_tracker >= #{min_gem_version}"
        end

        def schema_version
          @schema_version ||= Integer(@metadata.fetch("schema_version", 1))
        end

        def models_with_metadata
          raw_models = @registry.fetch("models", {})
          Registry.normalize_price_entries(raw_models, context: CONTEXT).to_h do |model, prices|
            [model, (raw_models[model] || {}).slice(*Registry::METADATA_KEYS).merge(prices)]
          end
        end

        def service_charges
          @registry["service_charges"]
        end
      end
    end
  end
end
