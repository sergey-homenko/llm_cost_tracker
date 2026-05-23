# frozen_string_literal: true

module LlmCostTracker
  module Masking
    SENSITIVE_KEYS = %i[provider_api_key_id provider_workspace_id provider_project_id].freeze
    MASK_TAIL_LENGTH = 4
    def self.mask_value(key, value)
      string = value.to_s
      return string unless SENSITIVE_KEYS.include?(key.to_sym)
      return string if string.length <= MASK_TAIL_LENGTH

      "***#{string[-MASK_TAIL_LENGTH, MASK_TAIL_LENGTH]}"
    end

    def self.format_attribution(attribution, separator: ", ")
      return "" if attribution.nil? || attribution.empty?

      attribution.map { |key, value| "#{key}=#{mask_value(key, value)}" }.join(separator)
    end

    def self.mask_hash(hash)
      return hash unless hash.is_a?(Hash)

      hash.each_with_object({}) do |(key, value), masked|
        masked[key] = case value
                      when Hash then mask_hash(value)
                      when Array then value.map { |entry| entry.is_a?(Hash) ? mask_hash(entry) : entry }
                      else
                        mask_value(key, value)
                      end
      end
    end
  end
end
