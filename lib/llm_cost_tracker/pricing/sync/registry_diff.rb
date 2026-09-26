# frozen_string_literal: true

module LlmCostTracker
  module Pricing
    module Sync
      module RegistryDiff
        class << self
          def call(current_models, updated_models)
            nested(
              Registry.normalize_price_entries(current_models, context: "current price table"),
              Registry.normalize_price_entries(updated_models, context: "updated price table")
            )
          rescue ArgumentError, TypeError => e
            raise Error, e.message
          end

          def nested(current, updated)
            (current.keys | updated.keys).sort.each_with_object({}) do |key, changes|
              fields = price_field_changes(current[key], updated[key])
              changes[key] = fields if fields.any?
            end
          end

          private

          def price_field_changes(current_entry, updated_entry)
            current_price = (current_entry || {}).transform_keys(&:to_s)
            updated_price = (updated_entry || {}).transform_keys(&:to_s)

            (current_price.keys | updated_price.keys).sort.each_with_object({}) do |field, changes|
              from = current_price[field]
              to = updated_price[field]
              next if from == to

              changes[field] = { "from" => from, "to" => to }
            end
          end
        end
      end
    end
  end
end
