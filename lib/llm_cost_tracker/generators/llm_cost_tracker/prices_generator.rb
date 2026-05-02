# frozen_string_literal: true

require "rails/generators"
require "yaml"

require_relative "../../pricing/registry"
require_relative "../../pricing/sync/registry_writer"

module LlmCostTracker
  module Generators
    class PricesGenerator < Rails::Generators::Base
      desc "Creates a local LLM Cost Tracker price snapshot"

      def create_prices_file
        LlmCostTracker::Pricing::Sync::RegistryWriter.new.call(
          path: File.join(destination_root, "config/llm_cost_tracker_prices.yml"),
          registry: YAML.safe_load_file(LlmCostTracker::Pricing::Registry::DEFAULT_PRICES_PATH, aliases: false) || {}
        )
      end
    end
  end
end
