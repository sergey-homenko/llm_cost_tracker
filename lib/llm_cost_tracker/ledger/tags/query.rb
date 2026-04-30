# frozen_string_literal: true

require "json"

require_relative "../schema/adapter"

module LlmCostTracker
  module Ledger
    module Tags
      module Query
        class << self
          def apply(model, tags)
            normalized_tags = (tags || {}).to_h.transform_keys(&:to_s).transform_values(&:to_s)
            return model.all if normalized_tags.empty?

            connection = model.connection
            json = normalized_tags.to_json

            if Schema::Adapter.postgresql?(connection)
              model.where("tags @> ?::jsonb", json)
            else
              model.where("JSON_CONTAINS(tags, ?)", json)
            end
          end
        end
      end
    end
  end
end
