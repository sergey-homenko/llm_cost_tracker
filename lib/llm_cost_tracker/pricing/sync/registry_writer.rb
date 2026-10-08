# frozen_string_literal: true

require "bigdecimal"
require "fileutils"
require "json"
require "yaml"

module LlmCostTracker
  module Pricing
    module Sync
      class RegistryWriter
        YAML_EXTENSIONS = %w[.yml .yaml].freeze
        MANUAL_SOURCE = "manual"

        def call(path:, registry:)
          payload = render(path: path, registry: registry)
          FileUtils.mkdir_p(File.dirname(path))
          temp_path = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
          File.write(temp_path, payload)
          File.rename(temp_path, path)
        ensure
          FileUtils.rm_f(temp_path) if temp_path && File.exist?(temp_path)
        end

        def render(path:, registry:)
          json = !yaml_file?(path)
          merged = canonicalize(merge_with_existing(path: path, registry: registry), json: json)
          json ? "#{JSON.pretty_generate(merged)}\n" : YAML.dump(merged)
        end

        private

        def canonicalize(value, json:)
          case value
          when Hash then value.sort_by { |key, _| key.to_s }.to_h { |key, item| [key, canonicalize(item, json: json)] }
          when Array then value.map { |item| canonicalize(item, json: json) }
          when BigDecimal, Float then canonical_number(value, json: json)
          else value
          end
        end

        def canonical_number(value, json:)
          json && defined?(JSON::Fragment) ? JSON::Fragment.new(value.to_f.to_s) : value.to_f
        end

        def merge_with_existing(path:, registry:)
          existing = read_existing(path)
          return registry unless existing.is_a?(Hash)

          merged = registry.dup
          merged["models"] = merged_models(registry, existing) if existing["models"].is_a?(Hash)
          if existing["service_charges"].is_a?(Hash)
            merged["service_charges"] = merged_service_charges(registry, existing)
          end
          merged
        end

        def merged_models(registry, existing)
          merged = registry.fetch("models", {}).dup
          existing.fetch("models", {}).each do |model, attrs|
            next unless attrs.is_a?(Hash) && attrs["_source"].to_s == MANUAL_SOURCE
            next if merged.key?(model)

            merged[model] = attrs
          end
          merged
        end

        def merged_service_charges(registry, existing)
          remote = registry.fetch("service_charges", {})
          existing.fetch("service_charges", {}).each_with_object(remote.dup) do |(provider, charges), merged|
            next unless charges.is_a?(Hash)
            next if merged.key?(provider)

            merged[provider] = charges
          end
        end

        def read_existing(path)
          return nil unless File.exist?(path)

          contents = File.read(path)
          return nil if contents.strip.empty?

          if yaml_file?(path)
            YAML.safe_load(contents, permitted_classes: [Symbol, Date, Time])
          else
            JSON.parse(contents)
          end
        rescue Errno::ENOENT, Psych::Exception, JSON::ParserError
          nil
        end

        def yaml_file?(path)
          YAML_EXTENSIONS.include?(File.extname(path).downcase)
        end
      end
    end
  end
end
