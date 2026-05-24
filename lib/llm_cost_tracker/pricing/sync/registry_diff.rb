# frozen_string_literal: true

module LlmCostTracker
  module Pricing
    module Sync
      module RegistryDiff
        class << self
          def call(current_models, updated_models)
            current_models = normalize_models(current_models)
            updated_models = normalize_models(updated_models)

            (current_models.keys | updated_models.keys).sort.each_with_object({}) do |model, changes|
              fields = price_field_changes(current_models[model], updated_models[model])
              changes[model] = fields if fields.any?
            end
          end

          private

          def price_field_changes(current_entry, updated_entry)
            current_price = current_entry || {}
            updated_price = updated_entry || {}

            (current_price.keys | updated_price.keys).sort.each_with_object({}) do |field, changes|
              from = current_price[field]
              to = updated_price[field]
              next if from == to

              changes[field] = { "from" => from, "to" => to }
            end
          end

          def normalize_models(models)
            Registry.normalize_price_table(models)
          rescue ArgumentError, TypeError => e
            raise Error, e.message
          end
        end
      end
    end
  end
end
