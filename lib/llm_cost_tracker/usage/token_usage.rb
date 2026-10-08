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
        new(**priced,
            total_tokens: total(values[:total_tokens], priced.values.sum),
            hidden_output_tokens: non_negative_int(values[:hidden_output_tokens]))
      end

      def self.build_from_tokens(tokens)
        return tokens if tokens.is_a?(self)
        raise ArgumentError, "tokens must be a Hash, got #{tokens.class}" unless tokens.respond_to?(:to_h)

        values = tokens.to_h.transform_keys(&:to_s)
        known = members.map(&:to_s)
        unknown = values.keys - known
        if unknown.any?
          hint = values.keys.intersect?(known) ? "" : ". Did you pass a raw provider response?"
          raise ArgumentError, "unknown token keys: #{unknown.inspect}; expected #{known.inspect}#{hint}"
        end

        build(**values.transform_keys(&:to_sym))
      end

      def self.non_negative_int(value)
        [value.to_i, 0].max
      end

      def self.total(declared, counted)
        declared ? [non_negative_int(declared), counted].max : counted
      end
      private_class_method :total
    end
  end
end
