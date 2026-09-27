# frozen_string_literal: true

require "json"
require "time"

require_relative "base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Litellm < Base
        SOURCE_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
        TOKEN_MODES = %w[chat responses].freeze
        FIELDS = {
          "input_cost_per_token" => "input",
          "output_cost_per_token" => "output",
          "cache_read_input_token_cost" => "cache_read_input"
        }.freeze
        FIELD_PATTERN = /\A(?<field>#{FIELDS.keys.join('|')})(?:_above_(?<thousands>\d+)k_tokens)?(?<batch>_batches)?\z/
        STANDARD_FIELD = /\A(?<context>above_context_)?(?<field>#{FIELDS.values.join('|')})\z/

        class << self
          def litellm_provider(value = nil)
            @litellm_provider = value if value
            @litellm_provider
          end
        end

        def call(html:, source_url: self.class.source_url, scraped_at: Time.now.utc.iso8601)
          prefix = "#{self.class.litellm_provider}/"
          models = parse_json(html).each_with_object({}) do |(key, entry), collected|
            next unless key.start_with?(prefix) && entry.is_a?(Hash) && TOKEN_MODES.include?(entry["mode"])

            fields = extract_fields(key, entry)
            collected[key.delete_prefix(prefix)] = fields if fields.key?("input") && fields.key?("output")
          end
          models = with_tiers(models)
          validate!(models)
          Result.new(
            source_url: source_url,
            scraped_at: scraped_at,
            models: models,
            deprecated_models: [],
            service_charges: {}
          )
        end

        private

        # A tier the provider documents as a multiple of its standard rates, e.g. "priority" at 2.0.
        def tier_prices(fields, tier, factor)
          fields.each_with_object({}) do |(field, value), prices|
            match = STANDARD_FIELD.match(field)
            prices["#{match[:context]}#{tier}_#{match[:field]}"] = (value * factor).round(6) if match
          end
        end

        def documented_factor(page, pattern, name)
          factor = page.to_s[pattern, 1]
          raise Error, "#{self.class.litellm_provider} #{name} rate not found in its docs" unless factor

          Float(factor)
        end

        def parse_json(body)
          catalogue = JSON.parse(body.to_s)
          raise Error, "LiteLLM price list is not a JSON object" unless catalogue.is_a?(Hash)

          catalogue
        rescue JSON::ParserError => e
          raise Error, "LiteLLM price list is invalid JSON: #{e.message}"
        end

        def extract_fields(key, entry)
          entry.each_with_object({}) do |(name, value), fields|
            match = FIELD_PATTERN.match(name)
            next unless match && value.is_a?(Numeric) && value.positive?

            field = "#{'batch_' if match[:batch]}#{FIELDS.fetch(match[:field])}"
            if match[:thousands]
              threshold = Integer(match[:thousands]) * 1000
              if fields.fetch("_context_price_threshold_tokens", threshold) != threshold
                raise Error, "LiteLLM #{key} mixes long-context thresholds"
              end

              fields["_context_price_threshold_tokens"] = threshold
              field = "above_context_#{field}"
            end
            fields[field] = (value * 1_000_000).round(6)
          end
        end
      end
    end
  end
end
