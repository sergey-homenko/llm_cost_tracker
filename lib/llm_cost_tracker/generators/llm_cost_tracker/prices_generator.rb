# frozen_string_literal: true

require "rails/generators"
require "yaml"

require_relative "../../pricing/registry"
require_relative "../../pricing/sync/registry_writer"

module LlmCostTracker
  module Generators
    class PricesGenerator < Rails::Generators::Base
      desc "Creates a local LLM Cost Tracker price snapshot"

      PRICES_PATH = "config/llm_cost_tracker_prices.yml"

      def create_prices_file
        payload = LlmCostTracker::Pricing::Sync::RegistryWriter.new.render(
          path: File.join(destination_root, PRICES_PATH),
          registry: YAML.safe_load_file(LlmCostTracker::Pricing::Registry::DEFAULT_PRICES_PATH, aliases: false) || {}
        )
        create_file(PRICES_PATH, payload)
      end
    end
  end
end
