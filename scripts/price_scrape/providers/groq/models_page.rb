# frozen_string_literal: true

require_relative "../base"
require_relative "table"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Groq < Base
        class ModelsPage
          MODEL_CARD_PATH = "/docs/model/"
          UNIT_PRICES = {
            "per hour" => ["transcription_minute", 60], "per 1M characters" => ["text_to_speech_character", 1]
          }.freeze

          def initialize(doc)
            @tables = Table.all(doc).select { |table| table.header?("MODEL ID") && table.header?("PRICE PER") }
          end

          def rows
            raise Error, "Groq token models pricing table not found" if @tables.empty?

            @tables.flat_map { |table| price_rows(table) }.group_by { |row| row[:id] }.to_h do |id, group|
              [id, group.size == 1 ? group.first : disambiguate(id, group)]
            end
          end

          private

          def price_rows(table)
            model = table.column("MODEL ID")
            price = table.column("PRICE PER")
            table.rows(model, price).filter_map do |row, cells|
              id = model_card_id(row) or next
              input, output, units = cell_prices(cells[price])
              next unless (input && output) || units.any?

              { id: id, name: Table.text(cells[model].text), input: input, output: output, units: units }
            end
          end

          def model_card_id(row)
            href = row.css("a").filter_map { |node| node["href"] }.find { |link| link.include?(MODEL_CARD_PATH) }
            return unless href

            id = href.split(MODEL_CARD_PATH, 2).last.to_s.split(/[?#]/).first
            id if id.to_s.match?(MODEL_ID)
          end

          def cell_prices(cell)
            text = Table.text(cell.text)
            units = UNIT_PRICES.filter_map do |unit, (field, divisor)|
              price = labeled_price(text, unit)
              [field, price / divisor] if price
            end
            [labeled_price(text, "input"), labeled_price(text, "output"), units.to_h]
          end

          def labeled_price(text, label)
            price = text[/\$\s*(\d+(?:\.\d+)?)\s*#{label}\b/i, 1]
            Float(price) if price
          end

          def disambiguate(id, group)
            signature = squash(id.split("/").last)
            consistent = group.select { |row| squash(row[:name]).include?(signature) }
            return consistent.first if consistent.size == 1

            names = group.map { |row| row[:name] }
            raise Error, "Groq pricing ambiguous model id #{id.inspect} across #{names.inspect}"
          end

          def squash(value) = value.to_s.downcase.gsub(/[^a-z0-9]/, "")
        end
      end
    end
  end
end
