# frozen_string_literal: true

require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/object/try"

require_relative "event_window"

module LlmCostTracker
  module Capture
    module SdkPayload
      class << self
        def normalize(value)
          case value
          when Hash then normalize_hash(value)
          when Array then value.map { |nested| normalize(nested) }
          when Symbol then value.to_s
          when NilClass then nil
          else normalize_object(value)
          end
        end

        private

        def normalize_hash(hash)
          hash.each_with_object({}) do |(key, nested), out|
            out[key.to_s] = normalize(nested) unless EventWindow::IGNORED_PAYLOAD_KEYS.include?(key.to_s)
          end
        end

        def normalize_object(value)
          converted = container_for(value)
          converted ? normalize(converted) : value.deep_dup
        end

        def container_for(value)
          value.try(:deep_to_h) || value.try(:to_h)
        rescue StandardError
          nil
        end
      end
    end
  end
end
