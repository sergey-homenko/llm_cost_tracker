# frozen_string_literal: true

module LlmCostTracker
  module Ledger
    module Storable
      NUL = "\u0000"
      REPLACEMENT = "�"
      STRING_LIMIT = 255
      INTEGER_MAX = (2**31) - 1
      LINE_ITEM_STRINGS = %i[kind direction modality cache_state unit currency cost_status pricing_basis price_key
                             price_source price_source_version provider_field provider_item_id].freeze

      class << self
        def text(value)
          return value unless value.is_a?(String)

          string = utf8(value)
          string.include?(NUL) ? string.delete(NUL) : string
        end

        def identifier(value)
          string = text(value)
          return string unless string.is_a?(String) && string.length > STRING_LIMIT

          string[0, STRING_LIMIT]
        end

        def json(value)
          case value
          when Hash then value.each_with_object({}) { |(key, nested), out| out[json(key)] = json(nested) }
          when Array then value.map { |nested| json(nested) }
          when Symbol then symbol(value)
          else text(value)
          end
        end

        def event(event)
          event.with(
            provider: text(event.provider),
            model: text(event.model),
            pricing_mode: text(event.pricing_mode),
            usage_source: text(event.usage_source),
            provider_response_id: text(event.provider_response_id),
            provider_project_id: text(event.provider_project_id),
            provider_api_key_id: text(event.provider_api_key_id),
            provider_workspace_id: text(event.provider_workspace_id),
            tags: event.tags && json(event.tags.to_h).freeze,
            pricing_snapshot: json(event.pricing_snapshot),
            line_items: Array(event.line_items).map { |line_item| line_item_values(line_item) }
          )
        end

        def token_counts(token_usage, event_id:)
          counts = token_usage.to_h
          return counts if counts.values.all? { |count| count <= INTEGER_MAX }

          LlmCostTracker::Logging.warn(
            "Event #{event_id}: token counts above #{INTEGER_MAX} were capped to fit the ledger's integer columns; " \
            "its cost was computed from the full counts"
          )
          counts.transform_values { |count| [count, INTEGER_MAX].min }
        end

        private

        def utf8(value)
          string = value
          string = string.dup.force_encoding(Encoding::UTF_8) if string.encoding == Encoding::BINARY
          unless string.encoding == Encoding::UTF_8
            string = string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: REPLACEMENT)
          end
          string.valid_encoding? ? string : string.scrub(REPLACEMENT)
        end

        def symbol(value)
          cleaned = text(value.to_s)
          cleaned == value.to_s ? value : cleaned.to_sym
        end

        def line_item_values(line_item)
          cleaned = LINE_ITEM_STRINGS.to_h { |member| [member, text(line_item.public_send(member))] }
          line_item.with(**cleaned, details: json(line_item.details))
        end
      end
    end
  end
end
