# frozen_string_literal: true

require "csv"
require "json"

module LlmCostTracker
  module Dashboard
    class CallsExport
      MYSQL_HINT = "NO_SKIP_SCAN(llm_cost_tracker_calls)"
      FORMULA_PREFIXES = ["=", "+", "-", "@", "\t", "\r"].freeze
      MASKED_FIELDS = %i[provider_api_key_id provider_workspace_id provider_project_id].freeze
      TEXT_FIELDS = %i[provider model provider_response_id cost_status].freeze
      FIELDS = [
        :tracked_at, :provider, :model, *Usage::TokenUsage.members, :total_cost, :cost_status, :pricing_snapshot,
        :latency_ms, :provider_response_id, :provider_project_id, :provider_api_key_id, :provider_workspace_id,
        :batch, :tags
      ].freeze

      def self.call(relation, limit:, batch_size:)
        new(relation, limit: limit, batch_size: batch_size).to_s
      end

      def initialize(relation, limit:, batch_size:)
        @relation = relation
        @limit = limit
        @batch_size = batch_size
      end

      def to_s
        CSV.generate do |csv|
          csv << FIELDS.map(&:to_s)
          each_call { |call| csv << FIELDS.map { |field| value(field, call) } }
        end
      end

      private

      attr_reader :relation, :limit, :batch_size

      def each_call(&)
        scope = relation.limit(limit)
        scope = scope.optimizer_hints(MYSQL_HINT) if Ledger::Schema::Adapter.mysql?(scope.connection)
        scope.pluck(:id).each_slice(batch_size) do |ids|
          calls = LlmCostTracker::Call.where(id: ids).preload(:tag_records).index_by(&:id)
          calls.values_at(*ids).compact.each(&)
        end
      end

      def value(field, call)
        case field
        when :tracked_at then call.tracked_at.utc.iso8601
        when *MASKED_FIELDS then formula_safe(Masking.mask_value(field, call[field]))
        when *TEXT_FIELDS then formula_safe(call[field])
        when :pricing_snapshot then formula_safe(Hash(call.pricing_snapshot).deep_stringify_keys.to_json)
        when :tags then formula_safe(call.tag_pairs.to_json)
        else call[field]
        end
      end

      def formula_safe(value)
        return if value.nil?

        string = value.to_s
        FORMULA_PREFIXES.include?(string.lstrip[0]) ? "'#{string}" : string
      end
    end
  end
end
