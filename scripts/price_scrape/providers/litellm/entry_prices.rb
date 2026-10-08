# frozen_string_literal: true

require_relative "../base"
require_relative "rates"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Litellm < Base
        class EntryPrices
          def initialize(entry, provider)
            @entry = entry
            @provider = provider
          end

          def fields(&)
            fields = rate_fields(&)
            fields = fields.merge(off_peak_fields(&)) if @entry.key?("off_peak_pricing")
            yield "reasoning tokens priced apart from output" if reasoning_priced_apart?
            yield "OCR annotation and batch OCR pages" if @entry.keys.intersect?(PAGE_FIELDS)
            @provider == "openai" ? with_fast_aliases(fields) : fields
          end

          def unknown_fields
            @entry.filter_map { |name, value| name if !known?(name) && name.match?(PRICE_FIELD) && value != 0 }
          end

          private

          def rate_fields(&)
            rates = Rates.new(@entry, @provider)
            low, high = contiguous_tiers(&)
            fields = low ? with_tiers(rates.fields, low, high) : rates.fields
            boundaries = low ? [*rates.thresholds, Integer(low.dig("range", 1))] : rates.thresholds
            with_threshold(fields, boundaries.uniq, &)
          end

          def contiguous_tiers
            low, high, *rest = @entry["tiered_pricing"]
            return unless low
            return [low, high] if high && rest.empty? && low.dig("range", 1) == high.dig("range", 0)

            yield "price tiers other than two contiguous ones (tiered_pricing)"
            nil
          end

          def with_tiers(fields, low, high)
            fields.merge(Rates.new(low).fields) { |_field, top, _tier| top }
                  .merge(Rates.new(high).fields.transform_keys { |field| "above_context_#{field}" })
          end

          def with_threshold(fields, boundaries)
            case boundaries.size
            when 0 then fields
            when 1 then fields.merge(Pricing::Registry::CONTEXT_THRESHOLD_KEY => threshold(boundaries.first))
            else
              yield "several long-context thresholds"
              fields.reject { |field, _| field.start_with?("above_context_") }
            end
          end

          def threshold(boundary) = INCLUSIVE_THRESHOLD_PROVIDERS.include?(@provider) ? boundary - 1 : boundary

          def off_peak_fields
            rates = off_peak_rates(@entry["off_peak_pricing"])
            yield "time-of-day prices outside weekday windows (off_peak_pricing)" unless rates
            rates.to_h
          end

          def off_peak_rates(pricing)
            return unless pricing.is_a?(Hash)

            windows = Array(pricing["windows"]).map { |window| off_peak_window(window.is_a?(Hash) ? window : {}) }
            Rates.new(pricing).fields.transform_keys { |field| field.sub(/\A(above_context_)?/, "\\1off_peak_") }
                 .merge(Pricing::Registry::OFF_PEAK_WINDOWS_KEY => Pricing::OffPeak.windows(windows, label: "windows"))
          rescue ArgumentError
            nil
          end

          def off_peak_window(window)
            hours = Array(window["hours_utc"]).map { |range| range.to_s.sub(/-00:00\z/, "-24:00") }
            { "weekdays" => window["weekdays"], "hours_utc" => hours }
          end

          def reasoning_priced_apart?
            output = @entry["output_cost_per_token"]
            @entry.fetch("output_cost_per_reasoning_token", output) != output
          end

          def with_fast_aliases(fields)
            aliases = fields.select { |field, _| field.include?("priority_") }
            fields.merge(aliases.transform_keys { |field| field.sub("priority_", "fast_") })
          end

          def known?(name)
            FIELD.match?(name) || UNIT_FIELDS.key?(name) ||
              UPLIFT_FIELDS.include?(name) || STRUCTURE_FIELDS.include?(name)
          end
        end
      end
    end
  end
end
