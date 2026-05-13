# frozen_string_literal: true

require "bigdecimal"
require "json"
require "time"

require_relative "fingerprint"
require_relative "../../providers/anthropic/tier_classification"

module LlmCostTracker
  module Reconciliation
    module Sources
      module AnthropicUsage
        FINGERPRINT_KEYS = %i[
          starting_at ending_at model workspace_id
          service_tier context_window cost_type token_type description
          inference_geo
        ].freeze
        ROW_TYPE_COST = "cost"
        AUTHORITY_COST_API = "cost_api"
        DEFAULT_METER = "tokens"

        module_function

        def parse(response, authority: AUTHORITY_COST_API, row_type: ROW_TYPE_COST)
          payload = coerce_hash(response)
          buckets = Array(payload[:data])
          buckets.flat_map do |bucket|
            rows_for_bucket(bucket, authority: authority, row_type: row_type)
          end.compact
        end

        def rows_for_bucket(bucket, authority:, row_type:)
          bucket = symbolize(bucket)
          starting_at = bucket[:starting_at]
          ending_at = bucket[:ending_at]
          return [] unless starting_at && ending_at

          period_start = parse_date(starting_at)
          period_end = end_inclusive_date(ending_at)

          Array(bucket[:results]).filter_map do |raw|
            row_for_result(raw,
                           period_start: period_start, period_end: period_end,
                           starting_at: starting_at, ending_at: ending_at,
                           authority: authority, row_type: row_type)
          end
        rescue ArgumentError
          []
        end

        def row_for_result(raw, period_start:, period_end:, starting_at:, ending_at:, authority:, row_type:)
          result = symbolize(raw)
          raw_amount = result[:amount]
          return nil if raw_amount.nil?

          fingerprint = fingerprint_for(result, starting_at: starting_at, ending_at: ending_at)
          {
            external_id: "cost-#{fingerprint}",
            period_start: period_start,
            period_end: period_end,
            billed_amount: dollars_from_cents(raw_amount),
            currency: (result[:currency] || "USD").to_s.upcase,
            metadata: metadata_for(result, authority: authority, row_type: row_type)
          }
        end

        def dollars_from_cents(amount)
          (BigDecimal(amount.to_s) / 100).to_s("F")
        end

        def metadata_for(result, authority:, row_type:)
          {
            "row_type" => row_type,
            "meter" => meter_for(result),
            "authority" => authority,
            "match_basis" => match_basis_for(result),
            "model" => result[:model],
            "pricing_mode" => pricing_mode_for(result),
            "context_window" => result[:context_window],
            "cost_type" => result[:cost_type],
            "description" => result[:description],
            "token_type" => result[:token_type],
            "inference_geo" => result[:inference_geo],
            "provider_workspace_id" => result[:workspace_id]
          }.compact
        end

        def meter_for(result)
          case result[:cost_type].to_s
          when "web_search" then "web_search"
          when "code_execution" then "code_execution_hour"
          when "session_usage" then "session_usage"
          when "tokens" then token_meter(result[:token_type].to_s)
          else DEFAULT_METER
          end
        end

        def token_meter(token_type)
          return "cache_read_input_tokens" if token_type.include?("cache_read")
          return "cache_creation_input_tokens" if token_type.include?("cache_creation")
          return "input_tokens" if token_type.include?("input")
          return "output_tokens" if token_type.include?("output")

          DEFAULT_METER
        end

        def pricing_mode_for(result)
          modes = []
          modes << "batch" if result[:service_tier].to_s.downcase == "batch"
          if LlmCostTracker::Providers::Anthropic::TierClassification.data_residency_geo?(result[:inference_geo])
            modes << "data_residency"
          end
          modes.empty? ? nil : modes.uniq.join("_")
        end

        def match_basis_for(result)
          return "workspace" if result[:workspace_id]
          return "model" if result[:model]

          "period_only"
        end

        def fingerprint_for(result, starting_at:, ending_at:)
          attributes = result.merge(starting_at: normalized_epoch(starting_at),
                                    ending_at: normalized_epoch(ending_at))
          Fingerprint.compute(FINGERPRINT_KEYS, attributes)
        end

        def normalized_epoch(value)
          return value.to_i if value.is_a?(Numeric)

          Time.parse(value.to_s).utc.to_i
        rescue ArgumentError
          value.to_s
        end

        def parse_date(value)
          return value if value.is_a?(Date)
          return Time.at(value).utc.to_date if value.is_a?(Numeric)

          Time.parse(value.to_s).utc.to_date
        end

        def end_inclusive_date(value)
          time = case value
                 when Numeric then Time.at(value).utc
                 when Date then value.to_time.utc
                 else Time.parse(value.to_s).utc
                 end
          (time - 1).utc.to_date
        end

        def coerce_hash(response)
          return {} if response.nil?
          return symbolize(response) if response.is_a?(Hash)

          parsed = JSON.parse(response.to_s)
          raise ArgumentError, "Anthropic Usage payload must be a JSON object" unless parsed.is_a?(Hash)

          symbolize(parsed)
        rescue JSON::ParserError => e
          raise ArgumentError, "Unable to parse Anthropic Usage payload: #{e.message}"
        end

        def symbolize(hash)
          hash.to_h.transform_keys { |key| key.to_s.to_sym }
        end
      end
    end
  end
end
