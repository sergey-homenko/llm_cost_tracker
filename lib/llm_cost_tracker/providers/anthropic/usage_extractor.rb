# frozen_string_literal: true

require_relative "../../billing/line_item"
require_relative "../../logging"
require_relative "../../pricing/mode"
require_relative "../../token_usage"
require_relative "server_tools"
require_relative "tier_classification"

module LlmCostTracker
  module Providers
    module Anthropic
      module UsageExtractor
        module_function

        def token_usage(usage)
          input = usage[:input_tokens].to_i
          output = usage[:output_tokens].to_i
          cache_read = usage[:cache_read_input_tokens].to_i
          cache_write, cache_write_extended = cache_writes(usage)
          hidden_output = hidden_output_tokens(usage)

          TokenUsage.build(
            input_tokens: input,
            output_tokens: output,
            cache_read_input_tokens: cache_read,
            cache_write_input_tokens: cache_write,
            cache_write_extended_input_tokens: cache_write_extended,
            hidden_output_tokens: hidden_output
          )
        end

        def pricing_mode(request:, usage:)
          speed = usage&.dig(:speed) || request&.dig(:speed)
          service_tier = usage&.dig(:service_tier) || request&.dig(:service_tier)
          service_tier = nil if TierClassification.standard_equivalent_tier?(service_tier)
          geo = (usage&.dig(:inference_geo) || request&.dig(:inference_geo)).to_s.downcase

          modes = [Pricing::Mode.normalize(speed), Pricing::Mode.normalize(service_tier)]
          modes << "data_residency" if TierClassification.data_residency_geo?(geo)
          modes = modes.compact.uniq
          modes.empty? ? nil : modes.join("_")
        end

        def service_line_items(usage)
          server_tool_use = usage[:server_tool_use]
          return [] unless server_tool_use.is_a?(Hash)

          ServerTools::LINE_ITEMS.filter_map do |component_key, count_key|
            quantity = server_tool_use[count_key].to_i
            next if quantity.zero?

            Billing::LineItem.build(
              component_key: component_key,
              quantity: quantity,
              cost_status: Billing::CostStatus::UNKNOWN,
              pricing_basis: :provider_usage,
              provider_field: "usage.server_tool_use.#{count_key}"
            )
          end
        end

        def cache_writes(usage)
          cache_creation = usage[:cache_creation]
          if cache_creation.is_a?(Hash)
            [cache_creation[:ephemeral_5m_input_tokens].to_i, cache_creation[:ephemeral_1h_input_tokens].to_i]
          else
            warn_unexpected_cache_creation(cache_creation, usage)
            [usage[:cache_creation_input_tokens].to_i, 0]
          end
        end

        def hidden_output_tokens(usage)
          value = usage[:thinking_tokens] ||
                  usage[:thinking_output_tokens] ||
                  usage.dig(:output_tokens_details, :reasoning_tokens)
          value.to_i
        end

        def warn_unexpected_cache_creation(cache_creation, usage)
          return if cache_creation.nil?
          return if usage.key?(:cache_creation_input_tokens)

          Logging.warn("Anthropic usage.cache_creation has unexpected shape: #{cache_creation.class}")
        end
      end
    end
  end
end
