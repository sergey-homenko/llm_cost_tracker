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
        temp_path = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
        File.write(temp_path, payload)
        File.rename(temp_path, path)
      ensure
        FileUtils.rm_f(temp_path) if temp_path && File.exist?(temp_path)
      end

      private

      def yaml_file?(path)
        YAML_EXTENSIONS.include?(File.extname(path).downcase)
      end
    end
  end
end
