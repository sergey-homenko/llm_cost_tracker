# frozen_string_literal: true

require "json"

module LlmCostTracker
  module PriceSync
    module Sources
      class OpenRouter < Source
        PER_TOKEN_TO_PER_MILLION = 1_000_000
        SUPPORTED_PREFIXES = %w[openai anthropic google].freeze
        URL = "https://openrouter.ai/api/v1/models"

        def priority
          20
        end

        def url
          URL
        end

        def fetch(current_models:, fetcher:)
          response = fetcher.get(url)
          payload = JSON.parse(response.body.to_s)
          index = payload.fetch("data", []).to_h { |entry| [entry["id"], entry] }

          prices = []
          missing_models = []

          current_models.each_key do |our_model|
            entry_id = ModelCatalog.resolve_from_openrouter(our_model, index)
            entry = entry_id && index[entry_id]

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
          pricing = entry["pricing"] || {}
          provider = entry["id"].to_s.split("/").first

          SUPPORTED_PREFIXES.include?(provider) &&
            pricing["prompt"] &&
            pricing["completion"]
        end

        def build_raw_price(model, entry, response)
          pricing = entry.fetch("pricing", {})
          provider = normalize_provider(entry.fetch("id").split("/").first)
          cache_read = price_per_million(pricing["input_cache_read"])
          cache_write = price_per_million(pricing["input_cache_write"])

          RawPrice.new(
            model: model,
            provider: provider,
            input: price_per_million(pricing["prompt"]),
            output: price_per_million(pricing["completion"]),
            cached_input: provider == "anthropic" ? nil : cache_read,
            cache_read_input: provider == "anthropic" ? cache_read : nil,
            cache_creation_input: provider == "anthropic" ? cache_write : nil,
            source: name,
            source_version: response_version(response),
            fetched_at: response.fetched_at
          )
        end

        def normalize_provider(provider)
          return "gemini" if provider == "google"

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
