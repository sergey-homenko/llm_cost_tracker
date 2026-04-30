# frozen_string_literal: true

require "rails/generators"

require_relative "../../pricing/registry"
require_relative "../../pricing/sync/registry_loader"
require_relative "../../pricing/sync/registry_writer"

module LlmCostTracker
  module Generators
    class PricesGenerator < Rails::Generators::Base
      desc "Creates a local LLM Cost Tracker price snapshot"

      def create_prices_file
        registry = LlmCostTracker::Pricing::Sync::RegistryLoader.new.call(
          path: LlmCostTracker::Pricing::Registry::DEFAULT_PRICES_PATH,
          seed_path: LlmCostTracker::Pricing::Registry::DEFAULT_PRICES_PATH
        )
        LlmCostTracker::Pricing::Sync::RegistryWriter.new.call(
          path: File.join(destination_root, "config/llm_cost_tracker_prices.yml"),
          registry: registry
        )
      end
    end
  end
end
