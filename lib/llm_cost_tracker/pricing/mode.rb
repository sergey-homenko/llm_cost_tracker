# frozen_string_literal: true

module LlmCostTracker
  module Pricing
    class Mode
      STANDARD_MODE_VALUES = %i[auto default standard standard_only].freeze
      COMPOUND_MODIFIERS = %w[data_residency].freeze

      attr_reader :modifiers

      def self.normalize(value)
        return nil if value.nil?

        symbol = normalize_string(value.to_s)
        return nil unless symbol

        STANDARD_MODE_VALUES.include?(symbol) ? nil : symbol
      end

      def self.normalize_string(value)
        normalized = value.strip
        return nil if normalized.empty?

        normalized.downcase.tr("-", "_").to_sym
      end
      private_class_method :normalize_string

      def self.parse(value)
        return value if value.is_a?(self)
        return new([]) if value.nil?

        new(tokenize(value.to_s))
      end

      def self.tokenize(value)
        remaining = value.to_s.downcase.tr("-", "_")
        tokens = []
        loop do
          break if remaining.empty?

          compound = COMPOUND_MODIFIERS.find do |token|
            remaining == token || remaining.start_with?("#{token}_")
          end
          if compound
            tokens << compound.to_sym
            remaining = remaining.delete_prefix(compound).delete_prefix("_")
          else
            first, _, rest = remaining.partition("_")
            tokens << first.to_sym unless first.empty?
            remaining = rest
          end
        end
        tokens
      end

      def initialize(modifiers)
        @modifiers = Array(modifiers).map(&:to_sym).uniq.sort
        freeze
      end

      def empty?
        modifiers.empty?
      end

      def include?(modifier)
        modifiers.include?(modifier.to_sym)
      end

      def canonical
        modifiers.join("_")
      end
      alias to_s canonical

      def to_sym
        empty? ? nil : canonical.to_sym
      end

      def permutations
        return [canonical] if modifiers.size <= 1

        modifiers.permutation.map { |permutation| permutation.join("_") }.uniq
      end

      def ==(other)
        other.is_a?(self.class) && modifiers == other.modifiers
      end
      alias eql? ==

      def hash
        modifiers.hash
      end
    end
  end
end
