# frozen_string_literal: true

require_relative "../base"
require_relative "deprecated_models"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Openai < Base
        class Catalogue
          QUALIFIER = /\s*\(<\d+K context length\)\z/
          ENTRY_NAME = /\A- \[([^\]]+)\]/
          ENTRY_PAGE_ID = %r{\A- \[[^\]]+\]\(/api/docs/models/([^()/]+)\.md\)}
          ENTRY_MODEL_ID = /Model ID: `([^`]+)`/

          def initialize(markdown)
            @entries = markdown.to_s.each_line.with_object({}) do |line, entries|
              name = line[ENTRY_NAME, 1]
              model_id = line[ENTRY_PAGE_ID, 1] || line[ENTRY_MODEL_ID, 1]
              entries[name] = model_id if name && model_id
            end
          end

          def model_id(display_name)
            name = display_name.to_s.strip.sub(QUALIFIER, "")
            model_ids = @entries.values
            extends = name.match?(DeprecatedModels::MODEL_ID) && model_ids.any? { |id| name.start_with?("#{id}-") }
            @entries[name] || (name if model_ids.include?(name) || extends)
          end

          def model_id!(display_name)
            name = display_name.to_s.strip
            model_id(name) or raise Error, "no model ID for OpenAI price row #{name.inspect}"
          end
        end
      end
    end
  end
end
