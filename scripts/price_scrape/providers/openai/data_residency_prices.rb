# frozen_string_literal: true

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Openai
        module DataResidencyPrices
          MODELS = %w[gpt-5.5 gpt-5.5-pro gpt-5.4 gpt-5.4-mini gpt-5.4-nano gpt-5.4-pro].freeze

          class << self
            def call(models)
              models.each_with_object({}) do |(model_id, fields), priced|
                priced[model_id] = if MODELS.include?(model_id)
                                     fields.merge(data_residency_prices(fields))
                                   else
                                     fields
                                   end
              end
            end

            private

            def data_residency_prices(fields)
              fields.each_with_object({}) do |(field, value), prices|
                next unless data_residency_price_field?(field)

                prices[data_residency_field(field)] = (value * 1.1).round(6)
              end
            end

            def data_residency_price_field?(field)
              field.to_s.match?(/\A(?:above_context_)?(?:(?:batch|flex|priority)_)?(?:input|output|cache_read_input)\z/)
            end

            def data_residency_field(field)
              name = field.to_s
              if name.start_with?("above_context_")
                rest = name.delete_prefix("above_context_")
                "above_context_#{data_residency_field(rest)}"
              elsif (match = name.match(/\A(batch|flex|priority)_(.+)\z/))
                "#{match[1]}_data_residency_#{match[2]}"
              else
                "data_residency_#{name}"
              end
            end
          end
        end
      end
    end
  end
end
