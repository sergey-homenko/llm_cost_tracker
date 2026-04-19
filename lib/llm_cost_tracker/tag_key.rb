# frozen_string_literal: true

module LlmCostTracker
  module TagKey
    PATTERN = /\A[\w.-]+\z/

    class << self
      def validate!(key, error_class: ArgumentError)
        key = key.to_s
        return key if key.match?(PATTERN)

        raise error_class, "invalid tag key: #{key.inspect}"
      end
    end
  end
end
