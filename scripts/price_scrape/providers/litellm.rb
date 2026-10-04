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
        PROVIDERS = {
          "openai" => "openai", "anthropic" => "anthropic", "gemini" => "gemini", "xai" => "xai",
          "mistral" => "mistral", "groq" => "groq", "openrouter" => "openrouter", "deepseek" => "deepseek",
          "perplexity" => "perplexity", "cohere" => "cohere", "cohere_chat" => "cohere"
        }.freeze
        MODES = %w[chat responses embedding audio_transcription audio_speech realtime].freeze
        INCLUSIVE_THRESHOLD_PROVIDERS = %w[xai].freeze
        TOKEN_FIELDS = {
          "input_cost_per_token" => "input",
          "output_cost_per_token" => "output",
          "cache_read_input_token_cost" => "cache_read_input",
          "input_cost_per_token_cache_hit" => "cache_read_input",
          "cache_creation_input_token_cost_above_1hr" => "cache_write_extended_input",
          "cache_creation_input_token_cost" => "cache_write_input",
          "input_cost_per_audio_token" => "audio_input",
          "output_cost_per_audio_token" => "audio_output",
          "input_cost_per_image_token" => "image_input",
          "output_cost_per_image_token" => "image_output",
          "input_cost_per_video_token" => "video_input",
          "output_cost_per_video_token" => "video_output",
          "cache_read_input_audio_token_cost" => "audio_cache_read_input",
          "cache_read_input_image_token_cost" => "image_cache_read_input"
        }.freeze
        TIERS = { "batches" => "batch", "flex" => "flex", "priority" => "priority", "ultrafast" => "ultrafast" }.freeze
        UNIT_FIELDS = {
          "search_context_cost_per_query" => ["web_search_request", 1000, nil],
          "google_maps_grounding_cost_per_query" => ["maps_grounding_request", 1000, nil],
          "input_cost_per_second" => ["transcription_minute", 60, "audio_transcription"],
          "input_cost_per_character" => ["text_to_speech_character", 1_000_000, "audio_speech"]
        }.freeze
        UPLIFT_FIELDS = %w[regional_processing_uplift_multiplier_us regional_processing_uplift_multiplier_eu].freeze
        STRUCTURE_FIELDS = %w[tiered_pricing off_peak_pricing output_cost_per_reasoning_token].freeze
        PRICE_FIELD = /cost|pricing|multiplier/
        FIELD = /
          \A(?<field>#{TOKEN_FIELDS.keys.join('|')})
          (?:_above_(?<thousands>\d+)k_tokens)?
          (?:_(?<tier>#{TIERS.keys.join('|')}))?\z
        /x
        STANDARD_FIELD = /\A(?<context>above_context_)?(?<field>input|output|cache_read_input)\z/
        PROVIDER_FIELD = /\A(?:above_context_)?(?:batch_)?(?:input|output|cache_read_input)\z/
        Conversion = Data.define(:models, :entries, :unknown, :unrepresentable)

        class << self
          def litellm_provider(value = nil)
            @litellm_provider = value if value
            @litellm_provider
          end

          def convert(catalogue)
            conversion = Conversion.new(
              models: {},
              entries: {},
              unknown: Hash.new { |hash, key| hash[key] = [] },
              unrepresentable: Hash.new { |hash, key| hash[key] = [] }
            )
            catalogue.each do |key, entry|
              provider = entry.is_a?(Hash) && PROVIDERS[entry["litellm_provider"]]
              next unless provider && MODES.include?(entry["mode"]) && !key.start_with?("ft:")

              model = "#{provider}/#{key.delete_prefix("#{entry['litellm_provider']}/")}"
              next if conversion.entries.key?(model)

              fields = model_fields(entry, provider) { |reason| conversion.unrepresentable[reason] << model }
              unknown_fields(entry).each { |name| conversion.unknown[name] << model }
              conversion.entries[model] = entry
              conversion.models[model] = fields if fields.any?
            end
            conversion
          end

          def uplift(entry)
            entry.values_at(*UPLIFT_FIELDS).compact.first || entry.dig("provider_specific_entry", "us")
          end

          def entry_fields(entry, provider = nil)
            thresholds = []
            fields = entry.each_with_object({}) do |(name, value), converted|
              if (match = FIELD.match(name))
                next unless value.is_a?(Numeric) && value.positive?

                field = [TIERS[match[:tier]], TOKEN_FIELDS.fetch(match[:field])].compact.join("_")
                if match[:thousands]
                  thresholds << (Integer(match[:thousands]) * 1000)
                  field = "above_context_#{field}"
                end
                converted[field] ||= (value * 1_000_000).round(6)
              elsif (unit = unit_price(name, value, entry, provider))
                converted[unit.first] = unit.last
              end
            end
            [fields, thresholds.uniq]
          end

          private

          def model_fields(entry, provider, &)
            fields, thresholds = entry_fields(entry, provider)
            tiered(entry, fields, thresholds, &)
            if thresholds.size > 1
              yield "several long-context thresholds"
              fields = fields.reject { |field, _| field.start_with?("above_context_") }
            elsif thresholds.one?
              inclusive = INCLUSIVE_THRESHOLD_PROVIDERS.include?(provider) ? 1 : 0
              fields["_context_price_threshold_tokens"] = thresholds.first - inclusive
            end
            yield "time-of-day prices (off_peak_pricing)" if entry["off_peak_pricing"]
            output = entry["output_cost_per_token"]
            reasoning = entry.fetch("output_cost_per_reasoning_token", output)
            yield "reasoning tokens priced apart from output" if reasoning != output
            provider == "openai" ? with_fast_aliases(fields) : fields
          end

          def tiered(entry, fields, thresholds)
            low, high, *rest = entry["tiered_pricing"]
            return unless low

            unless high && rest.empty? && low.dig("range", 1) == high.dig("range", 0)
              yield "price tiers other than two contiguous ones (tiered_pricing)"
              return
            end
            thresholds << Integer(low.dig("range", 1))
            fields.merge!(entry_fields(low).first) { |_field, top, _tier| top }
            entry_fields(high).first.each { |field, value| fields["above_context_#{field}"] = value }
          end

          def with_fast_aliases(fields)
            aliases = fields.select { |field, _| field.include?("priority_") }
            fields.merge(aliases.transform_keys { |field| field.sub("priority_", "fast_") })
          end

          def unit_price(name, value, entry, provider)
            dimension, scale, mode = UNIT_FIELDS[name]
            value = value["search_context_size_medium"] if value.is_a?(Hash)
            return unless dimension && value.is_a?(Numeric) && value.positive?
            return unless mode.nil? || (mode == entry["mode"] && !entry.key?("input_cost_per_token"))

            dimension = "grounding_request" if dimension == "web_search_request" && provider == "gemini"
            [dimension, (value * scale).round(6)]
          end

          def unknown_fields(entry)
            entry.filter_map do |name, value|
              known = FIELD.match?(name) || UNIT_FIELDS.key?(name) || UPLIFT_FIELDS.include?(name) ||
                      STRUCTURE_FIELDS.include?(name)
              name if !known && name.match?(PRICE_FIELD) && value != 0
            end
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
          fields, thresholds = self.class.entry_fields(entry)
          raise Error, "LiteLLM #{key} mixes long-context thresholds" if thresholds.size > 1

          fields["_context_price_threshold_tokens"] = thresholds.first if thresholds.one?
          fields.select { |field, _| PROVIDER_FIELD.match?(field) || field == "_context_price_threshold_tokens" }
        end
      end
    end
  end
end
