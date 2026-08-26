# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Anthropic
      module UsageExtractor
        SERVER_TOOL_LINE_ITEMS = {
          "web_search_request" => :web_search_requests,
          "web_fetch_request" => :web_fetch_requests
        }.freeze
        DATA_RESIDENCY_GEOS = %w[us].freeze
        private_constant :SERVER_TOOL_LINE_ITEMS, :DATA_RESIDENCY_GEOS

        def self.token_usage(usage)
          input = usage[:input_tokens].to_i
          output = usage[:output_tokens].to_i
          cache_read = usage[:cache_read_input_tokens].to_i
          cache_write, cache_write_extended = cache_writes(usage)

          Usage::TokenUsage.build(
            input_tokens: input,
            output_tokens: output,
            cache_read_input_tokens: cache_read,
            cache_write_input_tokens: cache_write,
            cache_write_extended_input_tokens: cache_write_extended,
            hidden_output_tokens: usage.dig(:output_tokens_details, :thinking_tokens).to_i
          )
        end

        def self.pricing_mode(request:, usage:)
          speed = usage&.dig(:speed) || request&.dig(:speed)
          service_tier = usage&.dig(:service_tier) || request&.dig(:service_tier)
          geo = (usage&.dig(:inference_geo) || request&.dig(:inference_geo)).to_s.downcase

          modes = [Pricing::Mode.normalize(speed), Pricing::Mode.normalize(service_tier)]
          modes << "data_residency" if DATA_RESIDENCY_GEOS.include?(geo)
          Pricing::Mode.compose(modes)
        end

        def self.service_line_items(usage)
          server_tool_use = usage[:server_tool_use]
          return [] unless server_tool_use.is_a?(Hash)

          SERVER_TOOL_LINE_ITEMS.filter_map do |dimension_key, count_key|
            quantity = server_tool_use[count_key].to_i
            next if quantity.zero?

            Charges::LineItem.build(
              dimension_key: dimension_key,
              quantity: quantity,
              cost_status: Charges::CostStatus::UNKNOWN,
              pricing_basis: "provider_usage",
              provider_field: "usage.server_tool_use.#{count_key}"
            )
          end
        end

        def self.cache_writes(usage)
          cache_creation = usage[:cache_creation]
          if cache_creation.is_a?(Hash)
            [cache_creation[:ephemeral_5m_input_tokens].to_i, cache_creation[:ephemeral_1h_input_tokens].to_i]
          else
            warn_unexpected_cache_creation(cache_creation, usage)
            [usage[:cache_creation_input_tokens].to_i, 0]
          end
        end

        def self.warn_unexpected_cache_creation(cache_creation, usage)
          return if cache_creation.nil?
          return if usage.key?(:cache_creation_input_tokens)

          Logging.warn("Anthropic usage.cache_creation has unexpected shape: #{cache_creation.class}")
        end
      end
    end
  end
end
