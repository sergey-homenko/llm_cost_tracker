# frozen_string_literal: true

require "time"

require_relative "../../reconciliation/coercion"
require_relative "../../reconciliation/fingerprint"

module LlmCostTracker
  module Providers
    module Openai
      module ReconciliationSource
        FINGERPRINT_KEYS = %i[start_time end_time line_item model project_id api_key_id organization_id].freeze
        ROW_TYPE_COST = "cost"
        AUTHORITY_COST_API = "cost_api"
        DEFAULT_METER = "tokens"

        module_function

        def parse(response, authority: AUTHORITY_COST_API, row_type: ROW_TYPE_COST)
          payload = LlmCostTracker::Reconciliation::Coercion.coerce_hash(response, label: "OpenAI Costs")
          buckets = Array(payload[:data])
          buckets.flat_map do |bucket|
            rows_for_bucket(bucket, authority: authority, row_type: row_type)
          end.compact
        end

        def rows_for_bucket(bucket, authority:, row_type:)
          bucket = LlmCostTracker::Reconciliation::Coercion.symbolize(bucket)
          start_time = bucket[:start_time]
          end_time = bucket[:end_time]
          return [] unless start_time && end_time

          period_start = epoch_to_date(start_time)
          period_end = end_inclusive_date(end_time)

          Array(bucket[:results]).filter_map do |raw|
            row_for_result(raw,
                           period_start: period_start, period_end: period_end,
                           start_time: start_time, end_time: end_time,
                           authority: authority, row_type: row_type)
          end
        rescue ArgumentError
          []
        end

        def row_for_result(raw, period_start:, period_end:, start_time:, end_time:, authority:, row_type:)
          result = LlmCostTracker::Reconciliation::Coercion.symbolize(raw)
          amount = LlmCostTracker::Reconciliation::Coercion.symbolize(result[:amount] || {})
          billed_amount = amount[:value]
          return nil if billed_amount.nil?

          fingerprint = fingerprint_for(result, start_time: start_time, end_time: end_time)
          {
            external_id: "cost-#{fingerprint}",
            period_start: period_start,
            period_end: period_end,
            billed_amount: billed_amount,
            currency: (amount[:currency] || "USD").to_s.upcase,
            metadata: metadata_for(result, authority: authority, row_type: row_type)
          }
        end

        def metadata_for(result, authority:, row_type:)
          {
            "row_type" => row_type,
            "meter" => meter_for(result),
            "authority" => authority,
            "match_basis" => match_basis_for(result),
            "line_item" => result[:line_item],
            "model" => result[:model],
            "provider_project_id" => result[:project_id],
            "provider_api_key_id" => result[:api_key_id],
            "provider_workspace_id" => result[:organization_id]
          }.compact
        end

        def meter_for(result)
          line_item = result[:line_item].to_s.downcase
          case line_item
          when /web search/, /search content/ then "web_search"
          when /file search/ then "file_search_storage"
          when /code interpreter/, /container/ then "container_session"
          else DEFAULT_METER
          end
        end

        def match_basis_for(result)
          return "project" if result[:project_id]
          return "api_key" if result[:api_key_id]
          return "model" if result[:model]

          "period_only"
        end

        def fingerprint_for(result, start_time:, end_time:)
          attributes = result.merge(
            start_time: LlmCostTracker::Reconciliation::Coercion.normalized_epoch(start_time),
            end_time: LlmCostTracker::Reconciliation::Coercion.normalized_epoch(end_time)
          )
          LlmCostTracker::Reconciliation::Fingerprint.compute(FINGERPRINT_KEYS, attributes)
        end

        def epoch_to_date(value)
          return Time.at(Integer(value)).utc.to_date if value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)

          Time.parse(value.to_s).utc.to_date
        end

        def end_inclusive_date(value)
          time = if value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)
                   Time.at(Integer(value)).utc
                 else
                   Time.parse(value.to_s).utc
                 end
          (time - 1).utc.to_date
        end
      end
    end
  end
end
