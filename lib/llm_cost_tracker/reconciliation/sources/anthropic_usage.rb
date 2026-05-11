# frozen_string_literal: true

require "json"
require "time"

require_relative "fingerprint"

module LlmCostTracker
  module Reconciliation
    module Sources
      module AnthropicUsage
        FINGERPRINT_KEYS = %i[
          starts_at ends_at model workspace_id api_key_id
          service_tier context_window token_type description
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
          starts_at = bucket[:starts_at]
          ends_at = bucket[:ends_at]
          return [] unless starts_at && ends_at

          period_start = parse_date(starts_at)
          period_end = end_inclusive_date(ends_at)

          Array(bucket[:results]).filter_map do |raw|
            row_for_result(raw,
                           period_start: period_start, period_end: period_end,
                           starts_at: starts_at, ends_at: ends_at,
                           authority: authority, row_type: row_type)
          end
        rescue ArgumentError
          []
        end

        def row_for_result(raw, period_start:, period_end:, starts_at:, ends_at:, authority:, row_type:)
          result = symbolize(raw)
          billed_amount = result[:amount]
          return nil if billed_amount.nil?

          fingerprint = fingerprint_for(result, starts_at: starts_at, ends_at: ends_at)
          {
            external_id: "cost-#{fingerprint}",
            period_start: period_start,
            period_end: period_end,
            billed_amount: billed_amount,
            currency: (result[:currency] || "USD").to_s.upcase,
            metadata: metadata_for(result, authority: authority, row_type: row_type)
          }
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
            "description" => result[:description],
            "token_type" => result[:token_type],
            "inference_geo" => result[:inference_geo],
            "speed" => result[:speed],
            "provider_workspace_id" => result[:workspace_id],
            "provider_api_key_id" => result[:api_key_id]
          }.compact
        end

        def meter_for(result)
          token_type = result[:token_type].to_s.downcase
          description = result[:description].to_s.downcase
          return "web_search" if description.include?("web search")
          return "code_execution_hour" if description.include?("code execution")
          return "cache_read_input_tokens" if token_type.include?("cache_read") || description.include?("cache read")
          return "cache_creation_input_tokens" if token_type.include?("cache_creation")
          return "input_tokens" if token_type.include?("input")
          return "output_tokens" if token_type.include?("output")

          DEFAULT_METER
        end

        DATA_RESIDENCY_GEOS = %w[us].freeze
        private_constant :DATA_RESIDENCY_GEOS

        def pricing_mode_for(result)
          modes = []
          modes << result[:speed].to_s.downcase if result[:speed].to_s.downcase == "fast"
          tier = result[:service_tier].to_s.downcase
          modes << tier if tier == "batch"
          geo = result[:inference_geo].to_s.downcase
          modes << "data_residency" if result[:data_residency] || DATA_RESIDENCY_GEOS.include?(geo)
          modes.empty? ? nil : modes.uniq.join("_")
        end

        def match_basis_for(result)
          return "api_key" if result[:api_key_id]
          return "workspace" if result[:workspace_id]

          "period_only"
        end

        def fingerprint_for(result, starts_at:, ends_at:)
          attributes = result.merge(starts_at: normalized_epoch(starts_at),
                                    ends_at: normalized_epoch(ends_at))
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
