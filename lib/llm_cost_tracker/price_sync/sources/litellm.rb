# frozen_string_literal: true

require "json"

module LlmCostTracker
  module PriceSync
    module Sources
      class Litellm < Source
        PER_TOKEN_TO_PER_MILLION = 1_000_000
        SUPPORTED_MODES = %w[chat completion embedding responses].freeze
        SUPPORTED_PROVIDERS = %w[openai anthropic gemini text-completion-openai].freeze
        URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"

        def priority
          10
        end

        def url
          URL
        end

        def fetch(current_models:, fetcher:)
          response = fetcher.get(url)
          payload = JSON.parse(response.body.to_s)

          prices = []
          missing_models = []

          current_models.each_key do |our_model|
            entry_id = ModelCatalog.resolve_from_litellm(our_model, payload)
            entry = entry_id && payload[entry_id]

            if entry && supported_entry?(entry)
              prices << build_raw_price(our_model, entry, response)
            else
              missing_models << our_model
            end
          end

          SourceResult.new(
            prices: prices,
            missing_models: missing_models.sort,
            source_version: response_version(response)
          )
        rescue JSON::ParserError => e
          raise Error, "Unable to parse #{url}: #{e.message}"
        end

        private

        def supported_entry?(entry)
          SUPPORTED_PROVIDERS.include?(entry["litellm_provider"]) &&
            SUPPORTED_MODES.include?(entry["mode"]) &&
            entry.key?("input_cost_per_token") &&
            entry.key?("output_cost_per_token")
        end

        def build_raw_price(model, entry, response)
          provider = normalize_provider(entry["litellm_provider"])
          cache_read = price_per_million(entry["cache_read_input_token_cost"])
          cache_write = price_per_million(entry["cache_creation_input_token_cost"])

          RawPrice.new(
            model: model,
            provider: provider,
            input: price_per_million(entry["input_cost_per_token"]),
            output: price_per_million(entry["output_cost_per_token"]),
            cache_read_input: cache_read,
            cache_write_input: cache_write,
            source: name,
            source_version: response_version(response),
            fetched_at: response.fetched_at
          )
        end

        def normalize_provider(provider)
          return "openai" if provider == "text-completion-openai"

          provider
        end

        def price_per_million(value)
          return nil if value.nil?

          value.to_f * PER_TOKEN_TO_PER_MILLION
        end
      end
    end
  end
end
