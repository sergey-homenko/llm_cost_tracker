# frozen_string_literal: true

require "rails/generators"

require_relative "../../price_registry"
require_relative "../../price_sync/registry_loader"
require_relative "../../price_sync/registry_writer"

module LlmCostTracker
  module Generators
    class PricesGenerator < Rails::Generators::Base
      desc "Creates a local LLM Cost Tracker price snapshot"

      def create_prices_file
        registry = LlmCostTracker::PriceSync::RegistryLoader.new.call(
          path: LlmCostTracker::PriceRegistry::DEFAULT_PRICES_PATH,
          seed_path: LlmCostTracker::PriceRegistry::DEFAULT_PRICES_PATH
        )
        LlmCostTracker::PriceSync::RegistryWriter.new.call(
          path: File.join(destination_root, "config/llm_cost_tracker_prices.yml"),
          registry: registry
        )
      end
    end
  end
end
