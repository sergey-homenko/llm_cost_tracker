# frozen_string_literal: true

require "date"
require "json"

require_relative "base"
require_relative "litellm/entry_prices"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Litellm < Base
        PRICES_URL = "https://raw.githubusercontent.com/BerriAI/litellm/%s/model_prices_and_context_window.json"
        SOURCE_URL = format(PRICES_URL, "main")
        MODELS_DEV_URL = "https://models.dev/api.json"
        TOKEN_MODES = %w[chat responses].freeze
        ROW_MODES = [*TOKEN_MODES, "embedding", "rerank"].freeze
        PROVIDERS = {
          "openai" => "openai", "anthropic" => "anthropic", "gemini" => "gemini", "xai" => "xai",
          "mistral" => "mistral", "groq" => "groq", "openrouter" => "openrouter", "deepseek" => "deepseek",
          "perplexity" => "perplexity", "cohere" => "cohere", "cohere_chat" => "cohere"
        }.freeze
        MODES = %w[chat responses embedding audio_transcription audio_speech realtime ocr rerank].freeze
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
          "input_cost_per_character" => ["text_to_speech_character", 1_000_000, "audio_speech"],
          "ocr_cost_per_page" => ["ocr_page", 1000, "ocr"],
          "input_cost_per_query" => ["rerank_search_unit", 1000, "rerank"]
        }.freeze
        UPLIFT_FIELDS = %w[regional_processing_uplift_multiplier_us regional_processing_uplift_multiplier_eu].freeze
        PAGE_FIELDS = %w[annotation_cost_per_page annotation_cost_per_page_batches ocr_cost_per_page_batches].freeze
        STRUCTURE_FIELDS = (%w[tiered_pricing off_peak_pricing output_cost_per_reasoning_token] + PAGE_FIELDS).freeze
        PRICE_FIELD = /cost|pricing|multiplier/
        FIELD = /
          \A(?<field>#{TOKEN_FIELDS.keys.join('|')})
          (?:_above_(?<thousands>\d+)k_tokens)?
          (?:_(?<tier>#{TIERS.keys.join('|')}))?\z
        /x
        DATED_SUFFIX = /-(?:\d{4}-\d{2}-\d{2}|\d{8})\z/
        TOLERANCE = 0.01
        Conversion = Data.define(:models, :entries, :unknown, :unrepresentable) do
          def self.empty
            listing = -> { Hash.new { |hash, key| hash[key] = [] } }
            new(models: {}, entries: {}, unknown: listing.call, unrepresentable: listing.call)
          end

          def add(model, entry, provider)
            prices = EntryPrices.new(entry, provider)
            fields = prices.fields { |reason| unrepresentable[reason] << model }
            prices.unknown_fields.each { |name| unknown[name] << model }
            entries[model] = entry
            models[model] = fields if fields.any?
          end
        end
        Gate = Data.define(:confirmed, :held, :unconfirmed) do
          def self.empty = new(confirmed: {}, held: {}, unconfirmed: [])

          def add(model, fields, theirs)
            ours = fields.values_at("input", "output").map(&:to_f)
            if theirs.nil? then unconfirmed << model
            elsif ours.zip(theirs).none? { |pair| Litellm.differ?(*pair) } then confirmed[model] = fields
            else held[model] = [ours, theirs]
            end
          end
        end

        class << self
          def convert(catalogue)
            catalogue.each_with_object(Conversion.empty) do |(key, entry), conversion|
              provider = entry.is_a?(Hash) && PROVIDERS[entry["litellm_provider"]]
              next unless provider && MODES.include?(entry["mode"]) && !key.start_with?("ft:")

              model = "#{provider}/#{key.delete_prefix("#{entry['litellm_provider']}/")}"
              conversion.add(model, entry, provider) unless conversion.entries.key?(model)
            end
          end

          def uplift(entry)
            entry.values_at(*UPLIFT_FIELDS).compact.first || entry.dig("provider_specific_entry", "us")
          end

          def confirmed_rows(provider, pages, official, scraped_at)
            models_dev = JSON.parse(pages[MODELS_DEV_URL].to_s)
            return unless models_dev.is_a?(Hash)

            conversion = convert(parse_json(pages.fetch(SOURCE_URL)))
            today = Date.parse(scraped_at).iso8601
            gate(provider, conversion, models_dev, official, today).confirmed.transform_values do |fields|
              fields.slice("input", "cache_read_input", "output").merge("_source" => "litellm")
            end
          rescue JSON::ParserError
            nil
          end

          def gate(provider, conversion, models_dev, written, today)
            listed = models_dev.dig(provider, "models") || {}
            candidates(provider, conversion, written, today).each_with_object(Gate.empty) do |(model, fields), gate|
              theirs = listed.dig(model, "cost")&.values_at("input", "output")&.map(&:to_f) if fields.key?("input")
              gate.add(model, fields, theirs)
            end
          end

          def current?(entry, fields, today)
            retired = entry["deprecation_date"].to_s
            (retired.empty? || retired >= today) &&
              (!TOKEN_MODES.include?(entry["mode"]) || (fields.key?("input") && fields.key?("output")))
          end

          def differ?(ours, theirs)
            return ours != theirs unless ours.is_a?(Numeric) && theirs.is_a?(Numeric)
            return ours != theirs if ours.zero? || theirs.zero?

            (ours - theirs).abs / [ours.abs, theirs.abs].max > TOLERANCE
          end

          def parse_json(body)
            catalogue = JSON.parse(body.to_s)
            raise Error, "LiteLLM price list is not a JSON object" unless catalogue.is_a?(Hash)

            catalogue
          rescue JSON::ParserError => e
            raise Error, "LiteLLM price list is invalid JSON: #{e.message}"
          end

          private

          def candidates(provider, conversion, written, today)
            conversion.models.filter_map do |key, fields|
              model = key.delete_prefix("#{provider}/")
              entry = conversion.entries.fetch(key)
              next if model == key || written.key?(model) || !ROW_MODES.include?(entry["mode"])

              undated = model.sub(DATED_SUFFIX, "")
              twins = [conversion.models["#{provider}/#{undated}"], written[undated]]
              next if undated != model && priced_alike?(fields, twins)

              [model, fields] if current?(entry, fields, today)
            end
          end

          def priced_alike?(fields, twins)
            twins.compact.any? { |twin| twin.values_at("input", "output") == fields.values_at("input", "output") }
          end
        end
      end
    end
  end
end
