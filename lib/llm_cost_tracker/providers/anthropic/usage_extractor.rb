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
        BILLED_REFUSAL_CATEGORIES = %w[bio frontier_llm reasoning_extraction].freeze
        BEDROCK_REGIONAL_PROFILE = /\A(?!global\.)[a-z]+\.anthropic\./
        private_constant :SERVER_TOOL_LINE_ITEMS,
                         :DATA_RESIDENCY_GEOS,
                         :BILLED_REFUSAL_CATEGORIES,
                         :BEDROCK_REGIONAL_PROFILE

        class << self
          def token_usage(usage)
            entries = [usage, *iterations(usage, "compaction")]
            writes = entries.map { |entry| cache_writes(entry) }

            Usage::TokenUsage.build(
              input_tokens: entries.sum { |entry| entry[:input_tokens].to_i },
              output_tokens: entries.sum { |entry| entry[:output_tokens].to_i },
              cache_read_input_tokens: entries.sum { |entry| entry[:cache_read_input_tokens].to_i },
              cache_write_input_tokens: writes.sum(&:first),
              cache_write_extended_input_tokens: writes.sum(&:last),
              hidden_output_tokens: usage.dig(:output_tokens_details, :thinking_tokens).to_i
            )
          end

          def served_model(usage, content = nil)
            served = iterations(usage, "fallback_message").last&.dig(:model)
            served ||= fallback_blocks(content).last&.dig(:to, :model)
            served&.to_s.presence
          end

          def iteration_line_items(usage, content: nil)
            other_model_iterations(usage, content).map do |iteration|
              tokens = token_usage(iteration)
              Charges::LineItem.build(
                dimension_key: "model_iteration",
                quantity: 1,
                pricing_basis: "provider_usage",
                provider_field: "usage.iterations.#{iteration[:type]}",
                details: tokens.to_h.select { |_key, count| count.positive? }.merge(model: iteration[:model].to_s)
              )
            end
          end

          def refusal_line_items(usage, stop_reason:, refusal_category:)
            return [] unless stop_reason.to_s == "refusal" && token_usage(usage).output_tokens.zero?
            return [] if BILLED_REFUSAL_CATEGORIES.include?(refusal_category.to_s)

            [Charges::LineItem.build(
              dimension_key: "billed_request",
              quantity: 1,
              rate_amount: 0,
              cost: 0,
              pricing_basis: "provider_usage",
              price_source: "provider_response",
              provider_field: "stop_details.category",
              details: { category: refusal_category&.to_s }.compact
            )]
          end

          def pricing_mode(request:, usage:, host: nil, model: request&.dig(:model))
            modes = %i[speed service_tier].map { |key| Pricing::Mode.normalize(reported(key, usage, request)) }
            modes << "data_residency" if data_residency?(usage, request) || regional_host?(host, model)
            Pricing::Mode.compose(modes)
          end

          def regional_host?(host, model)
            Openai::Hosts.vertex_non_global?(host) &&
              Pricing::Matcher.modifier_priced?(provider: "anthropic", model: model, modifier: "data_residency")
          end

          def service_line_items(usage)
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

          private

          def other_model_iterations(usage, content)
            iterations(usage, "advisor_message") + billed_fallback_iterations(usage, content)
          end

          def billed_fallback_iterations(usage, content)
            served = served_model(usage, content)
            return [] unless served

            categories = fallback_blocks(content).map { |block| block.dig(:trigger, :category).to_s }
            declined_hops(usage, served).zip(categories).flat_map do |hop, category|
              billed_hop?(hop, category) ? hop : []
            end
          end

          def declined_hops(usage, served)
            declined = iterations(usage, "message").reject { |entry| ["", served].include?(entry[:model].to_s) }
            declined.group_by { |entry| entry[:model].to_s }.values
          end

          def billed_hop?(hop, category)
            hop.any? { |entry| entry[:output_tokens].to_i.positive? } || BILLED_REFUSAL_CATEGORIES.include?(category)
          end

          def fallback_blocks(content)
            Array(content).select { |block| block.is_a?(Hash) && block[:type].to_s == "fallback" }
          end

          def iterations(usage, type)
            Array(usage[:iterations]).select { |entry| entry.is_a?(Hash) && entry[:type].to_s == type }
          end

          def reported(key, usage, request)
            usage&.dig(key) || request&.dig(key)
          end

          def data_residency?(usage, request)
            DATA_RESIDENCY_GEOS.include?(reported(:inference_geo, usage, request).to_s.downcase) ||
              bedrock_regional?(request&.dig(:model))
          end

          def bedrock_regional?(model)
            model.to_s.match?(BEDROCK_REGIONAL_PROFILE) &&
              Pricing::Matcher.modifier_priced?(provider: "bedrock", model: model.to_s, modifier: "data_residency")
          end

          def cache_writes(usage)
            cache_creation = usage[:cache_creation]
            if cache_creation.is_a?(Hash)
              five_minute = cache_creation[:ephemeral_5m_input_tokens].to_i
              one_hour = cache_creation[:ephemeral_1h_input_tokens].to_i
              [five_minute + [usage[:cache_creation_input_tokens].to_i - five_minute - one_hour, 0].max, one_hour]
            else
              warn_unexpected_cache_creation(cache_creation, usage)
              [usage[:cache_creation_input_tokens].to_i, 0]
            end
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
end
