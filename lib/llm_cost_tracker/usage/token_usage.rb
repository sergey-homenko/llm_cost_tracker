# frozen_string_literal: true

require_relative "catalog"

module LlmCostTracker
  module Usage
    TokenUsage = Data.define(*Catalog.token_priced.map(&:token_key), :total_tokens, :hidden_output_tokens) do
      def priced_quantities
        Catalog.token_priced.to_h { |dimension| [dimension.key, public_send(dimension.token_key)] }
      end

      def self.build(**values)
        unknown = values.keys - members
        raise ArgumentError, "unknown token keys: #{unknown.inspect}" if unknown.any?

        priced = Catalog.token_priced.to_h do |dimension|
          [dimension.token_key, non_negative_int(values[dimension.token_key])]
        end
        subtotal = priced.values.sum
        declared_total = values[:total_tokens]
        total = declared_total ? [non_negative_int(declared_total), subtotal].max : subtotal
        new(**priced, total_tokens: total, hidden_output_tokens: non_negative_int(values[:hidden_output_tokens]))
      end

      def self.build_from_tokens(tokens)
        return tokens if tokens.is_a?(self)
        raise ArgumentError, "tokens must be a Hash, got #{tokens.class}" unless tokens.respond_to?(:to_h)

        values = tokens.to_h.transform_keys(&:to_s)
        warn_on_unknown_keys(values)
        recognized = members.each_with_object({}) do |key, attributes|
          attributes[key] = values[key.to_s] if values.key?(key.to_s)
        end
        build(**recognized)
      end

      def self.warn_on_unknown_keys(values)
        return if values.empty?

        known = members.map(&:to_s)
        return if values.keys.intersect?(known)

        Logging.warn(
          "tokens hash contains no recognized keys (#{values.keys.inspect}); " \
          "expected one of #{known.inspect}. Did you pass a raw provider response?"
        )
      end

      def self.non_negative_int(value)
        [value.to_i, 0].max
      end
    end
  end
end
