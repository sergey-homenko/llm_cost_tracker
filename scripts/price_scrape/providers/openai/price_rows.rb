# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "nokogiri"

require_relative "../base"
require_relative "astro_payload"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Openai < Base
        class PriceRows
          include AstroPayload

          UNIT_PRICE = %r{\A\$([\d.]+)\s*/\s*(minute|1M characters)\z}i
          UNIT_FIELDS = { "minute" => "transcription_minute", "1m characters" => "text_to_speech_character" }.freeze
          MINUTE_PRICE = %r{\A\$([\d.]+)\s*/\s*minute\z}i
          TRANSCRIPTION_AUDIO_INPUT = {
            "gpt-4o-transcribe" => { rate: 6.0, per_minute: "0.006" },
            "gpt-4o-transcribe-diarize" => { rate: 6.0, per_minute: "0.006" },
            "gpt-4o-mini-transcribe" => { rate: 3.0, per_minute: "0.003" }
          }.freeze

          def initialize(catalogue)
            @catalogue = catalogue
          end

          def models(rows, fields)
            rows.each_with_object({}) do |row, models|
              cells = unwrap(row)
              next unless cells.is_a?(Array) && cells.size >= 4

              model_id = @catalogue.model_id!(unwrap(cells[0]))
              prices = price_fields(cells, fields)
              existing = models[model_id]
              if existing && existing != prices
                raise Error, "conflicting prices for #{model_id}: #{existing.inspect} vs #{prices.inspect}"
              end

              models[model_id] = prices
            end
          end

          def grouped_models(groups, fields)
            groups.each_with_object({}) do |group, models|
              group = unwrap(group)
              next unless group.is_a?(Hash)

              name = unwrap(group["model"]).to_s.strip
              model_id = @catalogue.model_id(name)
              rows = unwrap(group["rows"])
              next unless rows.is_a?(Array)

              prices = group_prices(rows, fields, model_id)
              next if prices.empty?
              raise Error, "no model ID for OpenAI price row #{name.inspect}" unless model_id

              models[model_id] = prices
            end
          end

          def group_rows(groups)
            groups.flat_map do |group|
              group = unwrap(group)
              rows = unwrap(group["rows"]) if group.is_a?(Hash)
              rows.is_a?(Array) ? rows : []
            end
          end

          private

          def group_prices(rows, fields, model_id)
            rows.each_with_object({}) do |row, prices|
              cells = unwrap(row)
              next unless cells.is_a?(Array) && cells.size >= 4

              prices.merge!(group_row_prices(cells, fields, model_id) || {})
            end
          end

          def group_row_prices(cells, fields, model_id)
            label = unwrap(cells[0])
            return price_fields([nil, *cells], fields) if label.is_a?(Numeric)

            unit_prices(cells) ||
              transcription_prices(cells, label, fields, model_id) ||
              modality_prices(cells, label, fields)
          end

          def unit_prices(cells)
            priced = cells.drop(1).map { |cell| unwrap(cell) } - ["-"]
            unit_price = priced.size == 1 && priced.first.to_s.match(UNIT_PRICE)
            { UNIT_FIELDS.fetch(unit_price[2].downcase) => Float(unit_price[1]) } if unit_price
          end

          def transcription_prices(cells, label, fields, model_id)
            minute_price = unwrap(cells[3]).to_s[MINUTE_PRICE, 1]
            return unless minute_price && label.to_s.start_with?("Transcription")

            {
              fields.fetch(:input) => parse_price(unwrap(cells[1])),
              AUDIO_FIELDS.fetch(:input) => transcription_audio_input(model_id, minute_price),
              fields.fetch(:output) => parse_price(unwrap(cells[2]))
            }
          end

          def transcription_audio_input(model_id, minute_price)
            audio = TRANSCRIPTION_AUDIO_INPUT.fetch(model_id) do
              raise Error, "no audio input rate for OpenAI transcription model #{model_id.inspect}"
            end
            unless minute_price == audio.fetch(:per_minute)
              raise Error, "OpenAI #{model_id} estimate is now $#{minute_price}/minute; recheck its audio input rate"
            end

            audio.fetch(:rate)
          end

          def modality_prices(cells, label, fields)
            modality_fields = { "Text" => fields, "Audio" => AUDIO_FIELDS, "Image" => TIER_IMAGE_FIELDS[fields] }[label]
            price_fields(cells, modality_fields) if modality_fields
          end

          def price_fields(cells, fields)
            input, cache_read, cache_write, output = price_cells(cells)
            prices = fields == AUDIO_FIELDS && input == "-" ? {} : { fields.fetch(:input) => parse_price(input) }
            { cache_read_input: cache_read, cache_write_input: cache_write, output: output }.each do |column, value|
              price = parse_optional_price(value)
              prices[fields[column]] = price if price && fields[column]
            end
            prices
          end

          def price_cells(cells)
            values = cells.drop(1).first(4).map { |cell| unwrap(cell) }
            values.size == 4 ? values : values.insert(2, nil)
          end

          def parse_price(value)
            return Float(value) if value.is_a?(Numeric)
            return 0.0 if value == "Free"
            if value.is_a?(Hash) && value.key?("__pricingHtml")
              return parse_price(Nokogiri::HTML.fragment(unwrap(value["__pricingHtml"]).to_s).text.strip)
            end

            match = value.to_s.match(/\A\$?\s*(\d+(?:\.\d+)?)\z/)
            raise Error, "unable to parse price #{value.inspect}" unless match

            Float(match[1])
          end

          def parse_optional_price(value)
            text = value.to_s.strip
            return nil if text.blank? || text == "-"

            parse_price(value)
          end
        end
      end
    end
  end
end
