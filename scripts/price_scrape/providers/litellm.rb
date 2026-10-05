# frozen_string_literal: true

require "date"
require "json"

require_relative "base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Litellm < Base
        PRICES_URL = "https://raw.githubusercontent.com/BerriAI/litellm/%s/model_prices_and_context_window.json"
        SOURCE_URL = format(PRICES_URL, "main")
        MODELS_DEV_URL = "https://models.dev/api.json"
        TOKEN_MODES = %w[chat responses].freeze
        ROW_MODES = [*TOKEN_MODES, "embedding"].freeze
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
        Conversion = Data.define(:models, :entries, :unknown, :unrepresentable)
        Gate = Data.define(:confirmed, :held, :unconfirmed)

        class << self
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
            result = Gate.new(confirmed: {}, held: {}, unconfirmed: [])
            candidates(provider, conversion, written, today).each do |model, fields|
              ours = fields.values_at("input", "output").map(&:to_f)
              theirs = listed.dig(model, "cost")&.values_at("input", "output")&.map(&:to_f)
              if theirs.nil? then result.unconfirmed << model
              elsif ours.zip(theirs).none? { |pair| differ?(*pair) } then result.confirmed[model] = fields
              else result.held[model] = [ours, theirs]
              end
            end
            result
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

          def entry_fields(entry, provider = nil)
            thresholds = Hash.new { |hash, field| hash[field] = [] }
            fields = entry.each_with_object({}) do |(name, value), converted|
              if (match = FIELD.match(name))
                next unless value.is_a?(Numeric) && value.positive?

                field = [TIERS[match[:tier]], TOKEN_FIELDS.fetch(match[:field])].compact.join("_")
                if match[:thousands]
                  field = "above_context_#{field}"
                  thresholds[field] << (Integer(match[:thousands]) * 1000)
                end
                converted[field] ||= (value * 1_000_000).round(6)
              elsif (unit = unit_price(name, value, entry, provider))
                converted[unit.first] = unit.last
              end
            end
            [fields, thresholds]
          end

          private

          def candidates(provider, conversion, written, today)
            conversion.models.filter_map do |key, fields|
              model = key.delete_prefix("#{provider}/")
              entry = conversion.entries.fetch(key)
              next if model == key || written.key?(model) || !ROW_MODES.include?(entry["mode"])

              base = model.sub(DATED_SUFFIX, "")
              twins = [conversion.models["#{provider}/#{base}"], written[base]].compact
              prices = fields.values_at("input", "output")
              next if base != model && twins.any? { |twin| twin.values_at("input", "output") == prices }

              [model, fields] if current?(entry, fields, today)
            end
          end

          def model_fields(entry, provider, &)
            fields, thresholds = entry_fields(entry, provider)
            boundaries = [*thresholds.values.flatten, tiered(entry, fields, &)].compact.uniq
            if boundaries.size > 1
              yield "several long-context thresholds"
              fields = fields.reject { |field, _| field.start_with?("above_context_") }
            elsif boundaries.one?
              inclusive = INCLUSIVE_THRESHOLD_PROVIDERS.include?(provider) ? 1 : 0
              fields["_context_price_threshold_tokens"] = boundaries.first - inclusive
            end
            if entry.key?("off_peak_pricing")
              off_peak = off_peak_fields(entry["off_peak_pricing"])
              yield "time-of-day prices outside weekday windows (off_peak_pricing)" unless off_peak
              fields.merge!(off_peak.to_h)
            end
            output = entry["output_cost_per_token"]
            reasoning = entry.fetch("output_cost_per_reasoning_token", output)
            yield "reasoning tokens priced apart from output" if reasoning != output
            yield "OCR annotation and batch OCR pages" if entry.keys.intersect?(PAGE_FIELDS)
            provider == "openai" ? with_fast_aliases(fields) : fields
          end

          def off_peak_fields(pricing)
            return unless pricing.is_a?(Hash)

            windows = Array(pricing["windows"]).map do |window|
              window = {} unless window.is_a?(Hash)
              hours = Array(window["hours_utc"]).map { |range| range.to_s.sub(/-00:00\z/, "-24:00") }
              { "weekdays" => window["weekdays"], "hours_utc" => hours }
            end
            rates = entry_fields(pricing).first
            rates.transform_keys { |field| field.sub(/\A(above_context_)?/, "\\1off_peak_") }
                 .merge(Pricing::Registry::OFF_PEAK_WINDOWS_KEY => Pricing::OffPeak.windows(windows, label: "windows"))
          rescue ArgumentError
            nil
          end

          def tiered(entry, fields)
            low, high, *rest = entry["tiered_pricing"]
            return unless low

            unless high && rest.empty? && low.dig("range", 1) == high.dig("range", 0)
              yield "price tiers other than two contiguous ones (tiered_pricing)"
              return
            end
            fields.merge!(entry_fields(low).first) { |_field, top, _tier| top }
            entry_fields(high).first.each { |field, value| fields["above_context_#{field}"] = value }
            Integer(low.dig("range", 1))
          end

          def with_fast_aliases(fields)
            aliases = fields.select { |field, _| field.include?("priority_") }
            fields.merge(aliases.transform_keys { |field| field.sub("priority_", "fast_") })
          end

          def unit_price(name, value, entry, provider)
            dimension, scale, mode = UNIT_FIELDS[name]
            value = value["search_context_size_medium"] if value.is_a?(Hash)
            return unless dimension && value.is_a?(Numeric) && value.positive?
            return unless mode.nil? || (mode == entry["mode"] && !entry["input_cost_per_token"].to_f.positive?)

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
      end
    end
  end
end
