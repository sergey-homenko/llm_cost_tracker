# frozen_string_literal: true

module LlmCostTracker
  module Pricing
    module Mode
      STANDARD_MODE_VALUES = %i[auto default standard standard_only unspecified].freeze
      COMPOUND_MODIFIERS = %i[data_residency].freeze
      KNOWN_MODIFIERS = %i[batch flex priority scale fast on_demand data_residency].freeze
      WARNED_TOKENS = Set.new
      WARNED_TOKENS_MUTEX = Mutex.new
      private_constant :WARNED_TOKENS, :WARNED_TOKENS_MUTEX

      def self.normalize(value)
        return nil if value.nil?

        symbol = normalize_string(value.to_s)
        return nil unless symbol
        return nil if STANDARD_MODE_VALUES.include?(symbol)

        warn_unknown_tokens(symbol)
        symbol
      end

      def self.merge(provider_mode, request_mode)
        return normalize(request_mode) if provider_mode.to_s.strip.empty?

        provider_tokens = tokenize(provider_mode) - STANDARD_MODE_VALUES
        request_host_tokens = tokenize(request_mode || "") & COMPOUND_MODIFIERS
        combined = provider_tokens | request_host_tokens
        return nil if combined.empty?

        normalize(combined.join("_"))
      end

      def self.tokenize(value)
        remaining = value.to_s.downcase.tr("-", "_")
        tokens = []
        loop do
          break if remaining.empty?

          compound = COMPOUND_MODIFIERS.find do |token|
            name = token.name
            remaining == name || remaining.start_with?("#{name}_")
          end
          if compound
            tokens << compound
            remaining = remaining.delete_prefix(compound.name).delete_prefix("_")
          else
            first, _, rest = remaining.partition("_")
            tokens << first.to_sym unless first.empty?
            remaining = rest
          end
        end
        tokens
      end

      def self.permutations_for(value)
        modifiers = tokenize(value).uniq.sort
        return [""] if modifiers.empty?
        return [modifiers.first.to_s] if modifiers.size == 1

        modifiers.permutation.map { |permutation| permutation.join("_") }.uniq
      end

      def self.normalize_string(value)
        normalized = value.strip
        return nil if normalized.empty?

        normalized.downcase.tr("-", "_").to_sym
      end
      private_class_method :normalize_string

      def self.warn_unknown_tokens(symbol)
        new_tokens = WARNED_TOKENS_MUTEX.synchronize do
          (tokenize(symbol) - KNOWN_MODIFIERS - STANDARD_MODE_VALUES).select { |token| WARNED_TOKENS.add?(token) }
        end
        return if new_tokens.empty?

        Logging.warn(
          "Unrecognized pricing_mode token(s) #{new_tokens.inspect} in #{symbol.inspect}; " \
          "the call will land with cost_status: unknown. " \
          "Known pricing_mode tokens: #{KNOWN_MODIFIERS.inspect}"
        )
      end
      private_class_method :warn_unknown_tokens
    end
  end
end
