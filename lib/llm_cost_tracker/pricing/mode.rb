# frozen_string_literal: true

module LlmCostTracker
  module Pricing
    module Mode
      STANDARD_MODE_VALUES = %w[auto default standard standard_only unspecified].freeze
      KNOWN_MODIFIERS = %w[batch flex priority scale fast on_demand data_residency].freeze
      HOST_DERIVED_MODIFIERS = %w[data_residency].freeze
      MAX_PERMUTED_MODIFIERS = 6

      def self.normalize(value)
        return nil if value.nil?

        mode = normalize_string(value.to_s)
        return nil unless mode
        return nil if STANDARD_MODE_VALUES.include?(mode)

        warn_unknown_tokens(mode)
        mode
      end

      def self.merge(provider_mode, request_mode)
        return normalize(request_mode) if provider_mode.to_s.strip.empty?

        provider_tokens = tokenize(provider_mode) - STANDARD_MODE_VALUES
        request_host_tokens = tokenize(request_mode || "") & HOST_DERIVED_MODIFIERS
        combined = provider_tokens | request_host_tokens
        return nil if combined.empty?

        normalize(combined.join("_"))
      end

      def self.compose(tokens)
        tokens = Array(tokens).compact.uniq
        tokens.empty? ? nil : tokens.join("_")
      end

      def self.tokenize(value)
        remaining = value.to_s.downcase.tr("-", "_")
        tokens = []
        loop do
          break if remaining.empty?

          known = KNOWN_MODIFIERS.find do |modifier|
            remaining == modifier || remaining.start_with?("#{modifier}_")
          end
          if known
            tokens << known
            remaining = remaining.delete_prefix(known).delete_prefix("_")
          else
            first, _, rest = remaining.partition("_")
            tokens << first unless first.empty?
            remaining = rest
          end
        end
        tokens
      end

      def self.permutations_for(value)
        modifiers = tokenize(value).uniq.sort
        return [""] if modifiers.empty?
        return [modifiers.first] if modifiers.size == 1
        return [modifiers.join("_")] if modifiers.size > MAX_PERMUTED_MODIFIERS

        modifiers.permutation.map { |permutation| permutation.join("_") }.uniq
      end

      def self.normalize_string(value)
        normalized = value.strip
        return nil if normalized.empty?

        normalized.downcase.tr("-", "_")
      end
      private_class_method :normalize_string

      def self.warn_unknown_tokens(mode)
        unknown = tokenize(mode) - KNOWN_MODIFIERS - STANDARD_MODE_VALUES
        return if unknown.empty?

        @warned_tokens ||= Set.new
        fresh = unknown.uniq.reject { |token| @warned_tokens.include?(token) }
        return if fresh.empty?

        @warned_tokens.merge(fresh)
        Logging.warn(
          "Unrecognized pricing_mode token(s) #{fresh.inspect} in #{mode.inspect}; " \
          "the call will land with cost_status: unknown. " \
          "Known pricing_mode tokens: #{KNOWN_MODIFIERS.inspect}"
        )
      end
      private_class_method :warn_unknown_tokens
    end
  end
end
