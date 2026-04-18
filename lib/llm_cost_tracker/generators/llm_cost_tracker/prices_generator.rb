# frozen_string_literal: true

require "rails/generators"

module LlmCostTracker
  module Generators
    class PricesGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates a local LlmCostTracker price override file"

      def create_prices_file
        template(
          "llm_cost_tracker_prices.yml.erb",
          "config/llm_cost_tracker_prices.yml"
        )
      end
    end
  end
end
