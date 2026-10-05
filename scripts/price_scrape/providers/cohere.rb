# frozen_string_literal: true

require "time"

require_relative "litellm"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Cohere < Litellm
        source_url SOURCE_URL
        min_models 0
        max_price 1000.0

        SOURCE_URLS = [source_url, MODELS_DEV_URL].freeze

        def call(html:, source_url: self.class.source_url, scraped_at: Time.now.utc.iso8601)
          pages = html.is_a?(Hash) ? html : { SOURCE_URL => html }
          rows = self.class.confirmed_rows("cohere", pages, {}, scraped_at)
          notes = rows ? [] : ["- `cohere`: models.dev was unreachable or invalid, so no LiteLLM-only row was written"]
          validate!(rows.to_h)
          Result.new(source_url:, scraped_at:, models: rows.to_h, deprecated_models: [], service_charges: {}, notes:)
        end
      end
    end
  end
end
