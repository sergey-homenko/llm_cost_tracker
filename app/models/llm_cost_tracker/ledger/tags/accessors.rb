# frozen_string_literal: true

require "json"

module LlmCostTracker
  module Ledger
    module Tags
      module Accessors
        def parsed_tags
          return tags.transform_keys(&:to_s) if tags.is_a?(Hash)

          JSON.parse(tags || "{}")
        rescue JSON::ParserError
          {}
        end
      end
    end
  end
end
