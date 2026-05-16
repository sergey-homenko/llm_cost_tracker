# frozen_string_literal: true

require "rails/generators"
require_relative "async_ingestion_generator"

module LlmCostTracker
  module Generators
    class DurableIngestionGenerator < Rails::Generators::Base
      desc "Deprecated alias for llm_cost_tracker:async_ingestion (removed in 1.0)."

      def deprecate_and_invoke
        say(
          "[llm_cost_tracker] generator llm_cost_tracker:durable_ingestion is deprecated; " \
          "use llm_cost_tracker:async_ingestion (removed in 1.0)",
          :yellow
        )
        invoke "llm_cost_tracker:async_ingestion"
      end
    end
  end
end
