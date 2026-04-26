# frozen_string_literal: true

module LlmCostTracker
  module PriceSync
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
          current_price = comparable_price(current_entry)
          updated_price = comparable_price(updated_entry)

          (current_price.keys | updated_price.keys).sort.each_with_object({}) do |field, changes|
            from = current_price[field]
            to = updated_price[field]
            next if from == to

            changes[field] = { "from" => from, "to" => to }
          end
        end

        def comparable_price(entry)
          normalize_hash(entry).slice(*PriceRegistry::PRICE_KEYS)
        end

        def normalize_models(models)
          normalize_hash(models).transform_values { |entry| normalize_hash(entry) }
        end

        def normalize_hash(hash)
          return {} if hash.nil?
          raise Error, "pricing entries must be hashes" unless hash.is_a?(Hash)

          hash.each_with_object({}) do |(key, value), normalized|
            normalized[key.to_s] = value
          end
        end
      end
    end
  end
end
