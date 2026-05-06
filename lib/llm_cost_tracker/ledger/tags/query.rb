# frozen_string_literal: true

require_relative "../schema/adapter"

module LlmCostTracker
  module Ledger
    module Tags
      module Query
        class << self
          def apply(tags)
            normalized_tags = (tags || {}).to_h.transform_keys(&:to_s).transform_values(&:to_s)
            return LlmCostTracker::Call.all if normalized_tags.empty?

            normalized_tags.inject(LlmCostTracker::Call.all) do |relation, (key, value)|
              relation.where(id: LlmCostTracker::CallTag.where(key: key,
                                                               value: value).select(:llm_cost_tracker_call_id))
            end
          end
        end
      end
    end
  end
end
