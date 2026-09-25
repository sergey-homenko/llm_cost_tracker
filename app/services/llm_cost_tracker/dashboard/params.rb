# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    module Params
      QUERY_KEYS = %i[from to provider model tag tag_value stream usage_source cost_status sort dir page per].freeze

      class << self
        def to_hash(value)
          return {} if value.nil?

          unsafe_hash = value.try(:to_unsafe_h)
          return unsafe_hash if unsafe_hash.is_a?(Hash)
          return value if value.is_a?(Hash)

          hash = value.try(:to_h)
          hash.is_a?(Hash) ? hash : {}
        rescue ArgumentError, TypeError
          {}
        end

        def scalar(value, name)
          if value.is_a?(Hash) || value.is_a?(Array) || value.respond_to?(:to_unsafe_h)
            raise InvalidFilterError, "#{name} must be a single value"
          end

          value.to_s
        end

        def tag_query(value)
          to_hash(value).each_with_object({}) do |(key, tag_value), tags|
            key = key.to_s
            tag_value = tag_value.to_s
            next if key.blank? || tag_value.blank?

            tags[key] = tag_value
          end
        end
      end
    end
  end
end
