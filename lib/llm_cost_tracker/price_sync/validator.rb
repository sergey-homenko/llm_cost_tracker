# frozen_string_literal: true

module LlmCostTracker
  module PriceSync
    class Validator
      Result = Data.define(:accepted, :rejected, :flagged)
      Issue = Data.define(:model, :reason, :old_price, :new_price)

      MAX_INPUT_PER_MILLION = 100.0
      MAX_OUTPUT_PER_MILLION = 500.0
      MAX_RELATIVE_CHANGE = 3.0

      def validate_batch(merged_prices, existing_registry:)
        merged_prices.each_with_object(Result.new(accepted: {}, rejected: [], flagged: [])) do |(model, price), result|
          old_price = normalize_entry(existing_registry[model])
          status, reason = validate(new_price: price, old_price: old_price)

          case status
          when :rejected
            result.rejected << Issue.new(model: model, reason: reason, old_price: old_price, new_price: price)
          when :flagged
            result.flagged << Issue.new(model: model, reason: reason, old_price: old_price, new_price: price)
            result.accepted[model] = price
          else
            result.accepted[model] = price
          end
        end
      end

      private

      def validate(new_price:, old_price:)
        overrides = Array(normalize_entry(old_price)["_validator_override"])

        return [:rejected, "input > $#{MAX_INPUT_PER_MILLION}/1M"] if new_price.input > MAX_INPUT_PER_MILLION
        return [:rejected, "output > $#{MAX_OUTPUT_PER_MILLION}/1M"] if new_price.output > MAX_OUTPUT_PER_MILLION
        return [:ok, nil] if overrides.include?("skip_relative_change")

        if old_price.any? && changed_too_much?(old_price, new_price)
          return [:flagged, "price changed >#{MAX_RELATIVE_CHANGE}x"]
        end

        [:ok, nil]
      end

      def changed_too_much?(old_price, new_price)
        %i[input output].any? do |field|
          old_value = old_price[field.to_s].to_f
          next false if old_value.zero?

          new_value = new_price.public_send(field).to_f
          next false if new_value.zero?

          ratio = [new_value / old_value, old_value / new_value].max
          ratio > MAX_RELATIVE_CHANGE
        end
      end

      def normalize_entry(entry)
        (entry || {}).each_with_object({}) do |(key, value), normalized|
          normalized[key.to_s] = value
        end
      end
    end
  end
end
