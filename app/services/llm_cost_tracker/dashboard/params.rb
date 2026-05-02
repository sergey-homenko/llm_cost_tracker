# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    module Params
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
