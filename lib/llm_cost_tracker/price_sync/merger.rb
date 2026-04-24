# frozen_string_literal: true

module LlmCostTracker
  module PriceSync
    class Merger
      Discrepancy = Data.define(:model, :field, :values)

      PRIORITY_ORDER = %i[litellm openrouter].freeze
      SUPPLEMENTAL_FIELDS = %i[cache_read_input cache_write_input].freeze

      def merge(results_by_source)
        prices = collect_prices(results_by_source)
        discrepancies = []

        merged = prices.group_by(&:model).sort.to_h.transform_values do |candidates|
          sorted = sort_candidates(candidates)
          discrepancies.concat(detect_discrepancies(sorted))
          fill_missing_fields(sorted.first, sorted.drop(1))
        end

        [merged, discrepancies]
      end

      private

      def collect_prices(results_by_source)
        results_by_source.flat_map do |source_name, result|
          result.prices.map do |price|
            price.with(source: source_name)
          end
        end
      end

      def sort_candidates(candidates)
        candidates.sort_by do |price|
          PRIORITY_ORDER.index(price.source.to_sym) || PRIORITY_ORDER.length
        end
      end

      def fill_missing_fields(primary, fallbacks)
        SUPPLEMENTAL_FIELDS.reduce(primary) do |current, field|
          next current if current.public_send(field)

          fallback = fallbacks.find { |candidate| candidate.public_send(field) }
          fallback ? current.with(field => fallback.public_send(field)) : current
        end
      end

      def detect_discrepancies(candidates)
        return [] if candidates.length < 2

        RawPrice::PRICE_FIELDS.filter_map do |field|
          values = candidates.each_with_object({}) do |price, collected|
            value = price.public_send(field)
            collected[price.source] = value unless value.nil?
          end
          next if values.size < 2
          next unless discrepant?(values.values)

          Discrepancy.new(model: candidates.first.model, field: field, values: values)
        end
      end

      def discrepant?(values)
        min, max = values.minmax
        return max != min if min.to_f.zero?

        ((max - min).abs / min.to_f) >= 0.05
      end
    end
  end
end
