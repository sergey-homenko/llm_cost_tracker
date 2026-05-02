# frozen_string_literal: true

require "yaml"

require_relative "../registry"

module LlmCostTracker
  module Pricing
    module Sync
      class RegistryLoader
        def self.call(path = nil)
          source_path = path || Registry::DEFAULT_PRICES_PATH
          YAML.safe_load_file(source_path, aliases: false) || {}
        rescue Errno::ENOENT, Psych::Exception, ArgumentError, TypeError => e
          raise Error, "Unable to load pricing registry #{source_path.inspect}: #{e.message}"
        end
      end
    end
  end
end
