# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "json"
require "time"

require_relative "../price_fields_validator"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Openrouter
        SOURCE_URL = "https://openrouter.ai/api/v1/models"
        MIN_MODELS_EXPECTED = 30
        MAX_PRICE_PER_MTOK = 5000.0
        ANCHOR_MODELS = %w[openai/gpt-4o anthropic/claude-sonnet-4].freeze
        PER_TOKEN_FIELDS = {
          "prompt" => "input",
          "completion" => "output",
          "input_cache_read" => "cache_read_input",
          "input_cache_write" => "cache_write_input"
        }.freeze

        Result = Data.define(:source_url, :scraped_at, :models, :deprecated_models, :service_charges)

        class Error < StandardError; end

        def call(html:, source_url: SOURCE_URL, scraped_at: Time.now.utc.iso8601)
          payload = parse_json(html)
          data = Array(payload["data"])
          raise Error, "OpenRouter API returned no models" if data.empty?

          models = data.each_with_object({}) do |entry, collected|
            model_id, fields = extract_model(entry)
            collected[model_id] = fields if model_id && fields.any?
          end

          PriceFieldsValidator.call(
            models,
            minimum: MIN_MODELS_EXPECTED,
            maximum: MAX_PRICE_PER_MTOK,
            anchors: ANCHOR_MODELS,
            error_class: Error
          )

          Result.new(
            source_url: source_url,
            scraped_at: scraped_at,
            models: models,
            deprecated_models: [],
            service_charges: {}
          )
        end

        private

        def parse_json(body)
          payload = JSON.parse(body.to_s)
          raise Error, "OpenRouter API returned non-Hash payload (#{payload.class})" unless payload.is_a?(Hash)

          payload
        rescue JSON::ParserError => e
          raise Error, "OpenRouter API returned invalid JSON: #{e.message}"
        end

        def extract_model(entry)
          return [nil, nil] unless entry.is_a?(Hash)

          model_id = entry["id"].to_s.strip
          return [nil, nil] if model_id.empty?

          pricing = entry["pricing"]
          return [nil, nil] unless pricing.is_a?(Hash)

          fields = PER_TOKEN_FIELDS.each_with_object({}) do |(source_key, target_key), out|
            converted = per_million(pricing[source_key])
            out[target_key] = converted if converted
          end
          [model_id, fields]
        end

        def per_million(value)
          return nil if value.nil?

          text = value.to_s.strip
          return nil if text.empty?

          per_token = Float(text)
          return nil unless per_token.positive?

          (per_token * 1_000_000).round(6)
        rescue ArgumentError, TypeError
          nil
        end
      end
    end
  end
end
