# frozen_string_literal: true

require "json"

module LlmCostTracker
  module TagAccessors
    def parsed_tags
      return tags.transform_keys(&:to_s) if tags.is_a?(Hash)

      JSON.parse(tags || "{}")
    rescue JSON::ParserError
      {}
    end
  end
end
