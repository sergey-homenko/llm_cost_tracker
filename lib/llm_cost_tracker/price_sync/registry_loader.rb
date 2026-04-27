# frozen_string_literal: true

require "json"
require "yaml"

module LlmCostTracker
  module PriceSync
    class RegistryLoader
      YAML_EXTENSIONS = %w[.yml .yaml].freeze
      MAX_FILE_BYTES = 2_097_152

      def call(path:, seed_path:)
        source_path = File.exist?(path.to_s) ? path.to_s : seed_path.to_s
        normalize_registry(load_registry_file(source_path))
      rescue Errno::ENOENT, JSON::ParserError, Psych::Exception, ArgumentError, TypeError => e
        raise Error, "Unable to load pricing registry #{source_path.inspect}: #{e.message}"
      end

      private

      def load_registry_file(path)
        raise ArgumentError, "pricing registry exceeds #{MAX_FILE_BYTES} bytes" if File.size(path) > MAX_FILE_BYTES

        contents = File.read(path)
        registry = yaml_file?(path) ? (YAML.safe_load(contents, aliases: false) || {}) : JSON.parse(contents)
        raise ArgumentError, "pricing registry must be a hash" unless registry.is_a?(Hash)

        registry
      end

      def normalize_registry(registry)
        {
          "metadata" => normalize_hash(registry.fetch("metadata", {}), label: "pricing metadata"),
          "models" => normalize_models(registry.fetch("models", {}))
        }
      end

      def normalize_models(models)
        normalize_hash(models, label: "pricing models").each_with_object({}) do |(model, entry), normalized|
          normalized[model.to_s] = normalize_hash(entry, label: "pricing model entry")
        end
      end

      def normalize_hash(hash, label:)
        return {} if hash.nil?
        raise ArgumentError, "#{label} must be a hash" unless hash.is_a?(Hash)

        hash.each_with_object({}) do |(key, value), normalized|
          normalized[key.to_s] = value
        end
      end

      def yaml_file?(path)
        YAML_EXTENSIONS.include?(File.extname(path).downcase)
      end
    end
  end
end
