# frozen_string_literal: true

require "digest"
require "json"
require "time"

module LlmCostTracker
  module Reconciliation
    module Sources
      module OpenaiUsage
        FINGERPRINT_KEYS = %i[start_time end_time line_item project_id api_key_id organization_id].freeze

        module_function

        def parse(response)
          payload = coerce_hash(response)
          buckets = Array(payload[:data])
          buckets.flat_map { |bucket| rows_for_bucket(bucket) }.compact
        end

        def rows_for_bucket(bucket)
          bucket = symbolize(bucket)
          start_time = bucket[:start_time]
          end_time = bucket[:end_time]
          return [] unless start_time && end_time

          period_start = epoch_to_date(start_time)
          period_end = epoch_to_date(end_time - 1)

          Array(bucket[:results]).filter_map do |raw|
            row_for_result(raw, period_start: period_start, period_end: period_end,
                                start_time: start_time, end_time: end_time)
          end
        end

        def row_for_result(raw, period_start:, period_end:, start_time:, end_time:)
          result = symbolize(raw)
          amount = symbolize(result[:amount] || {})
          billed_amount = amount[:value]
          return nil if billed_amount.nil?

          fingerprint = fingerprint_for(result, start_time: start_time, end_time: end_time)
          {
            external_id: "openai-cost-#{fingerprint}",
            period_start: period_start,
            period_end: period_end,
            billed_amount: billed_amount,
            currency: (amount[:currency] || "USD").to_s.upcase,
            metadata: metadata_for(result)
          }
        end

        def metadata_for(result)
          {
            "line_item" => result[:line_item],
            "provider_project_id" => result[:project_id],
            "provider_api_key_id" => result[:api_key_id],
            "provider_workspace_id" => result[:organization_id]
          }.compact
        end

        def fingerprint_for(result, start_time:, end_time:)
          source_string = FINGERPRINT_KEYS.map do |key|
            fingerprint_value(key, result, start_time: start_time, end_time: end_time).to_s
          end.join("|")
          Digest::SHA256.hexdigest(source_string)[0, 16]
        end

        def fingerprint_value(key, result, start_time:, end_time:)
          case key
          when :start_time then start_time
          when :end_time then end_time
          else result[key]
          end
        end

        def epoch_to_date(seconds)
          Time.at(Integer(seconds)).utc.to_date
        end

        def coerce_hash(response)
          return symbolize(response) if response.is_a?(Hash)

          parsed = JSON.parse(response.to_s)
          parsed.is_a?(Hash) ? symbolize(parsed) : {}
        rescue JSON::ParserError
          {}
        end

        def symbolize(hash)
          hash.to_h.transform_keys { |key| key.to_s.to_sym }
        end
      end
    end
  end
end
