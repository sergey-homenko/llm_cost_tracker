# frozen_string_literal: true

require_relative "../base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Openai < Base
        module DataResidencyPrices
          MODELS = %w[
            gpt-5.4 gpt-5.4-mini gpt-5.4-nano gpt-5.4-pro gpt-5.5 gpt-5.5-pro
            gpt-5.6-luna gpt-5.6-sol gpt-5.6-terra
          ].freeze
          PRICE_FIELD = /\A(?:above_context_)?(?:batch_|flex_|fast_)?(?:input|output|cache_(?:read|write)_input)\z/

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
                next unless field.to_s.match?(PRICE_FIELD)

                prices[data_residency_field(field)] = (value * 1.1).round(6)
              end
            end

            def data_residency_field(field)
              name = field.to_s
              if name.start_with?("above_context_")
                rest = name.delete_prefix("above_context_")
                "above_context_#{data_residency_field(rest)}"
              elsif (match = name.match(/\A(batch|flex|fast)_(.+)\z/))
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
