# frozen_string_literal: true

require_relative "../base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Openai < Base
        module AudioDurationPrices
          COST_HEADER = "Estimated cost"
          DURATION_BILLED_MODELS = %w[
            gpt-live-transcribe gpt-realtime-translate gpt-realtime-whisper gpt-transcribe
          ].freeze
          MINUTE_PRICE = %r{\$([\d.]+)\s*/\s*minute}i
          NO_TOKEN_PRICE = "-"

          class << self
            def call(doc)
              table = duration_table(doc)
              return {} unless table

              table.css("tbody tr").each_with_object({}) do |row, priced|
                cells = row.css("td").map { |cell| cell.text.gsub(/\s+/, " ").strip }
                model_id = duration_billed_model(cells)
                next unless model_id

                priced[model_id] = { "transcription_minute" => Float(cells[4][MINUTE_PRICE, 1]) }
              end
            end

            private

            def duration_table(doc)
              doc.css("table").find do |table|
                table.css("th").any? { |header| header.text.gsub(/\s+/, " ").strip == COST_HEADER }
              end
            end

            def duration_billed_model(cells)
              return nil unless cells.size >= 5
              return nil unless cells[2] == NO_TOKEN_PRICE && cells[3] == NO_TOKEN_PRICE
              return nil unless cells[4].match?(MINUTE_PRICE)

              cells[0] if DURATION_BILLED_MODELS.include?(cells[0])
            end
          end
        end
      end
    end
  end
end
