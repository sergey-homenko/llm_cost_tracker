# frozen_string_literal: true

require "json"

require_relative "../schema/adapter"

module LlmCostTracker
  module Ledger
    module Tags
      module Query
        class << self
          def apply(tags)
            normalized_tags = (tags || {}).to_h.transform_keys(&:to_s).transform_values(&:to_s)
            return Ledger::Call.all if normalized_tags.empty?

            connection = Ledger::Call.connection
            json = normalized_tags.to_json

            if Schema::Adapter.postgresql?(connection)
              Ledger::Call.where("tags @> ?::jsonb", json)
            else
              Ledger::Call.where("JSON_CONTAINS(tags, ?)", json)
            end
          end
        end
      end
    end
  end
end
