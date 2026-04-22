# frozen_string_literal: true

require "fileutils"
require "json"
require "yaml"

module LlmCostTracker
  module PriceSync
    class RegistryWriter
      YAML_EXTENSIONS = %w[.yml .yaml].freeze

      def call(path:, registry:)
        FileUtils.mkdir_p(File.dirname(path))
        payload = yaml_file?(path) ? YAML.dump(registry) : "#{JSON.pretty_generate(registry)}\n"
        File.write(path, payload)
      end

      private

      def yaml_file?(path)
        YAML_EXTENSIONS.include?(File.extname(path).downcase)
      end
    end
  end
end
