# frozen_string_literal: true

require "date"
require "nokogiri"

require_relative "../litellm"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Mistral < Litellm
        class DeprecatedCards
          TABLE = "//h3[normalize-space()='Deprecated & retired models']/following::"
          DATE = %r{\d{1,2}/\d{1,2}/\d{4}}

          def self.call(page, today) = new(Nokogiri::HTML(page)).call(today)

          def initialize(doc)
            @doc = doc
          end

          def call(today)
            rows, api, dates = table
            cards = rows.filter_map { |row| card(row.css("td"), api, dates) }
            cards.partition { |_card, _api, retires| retires >= today }
          end

          private

          def table
            headers = @doc.xpath("#{TABLE}thead[1]/tr/th").map { |header| header.text.strip }
            api = headers.index("API")
            dates = headers.index("DeprecationRetirement")
            rows = @doc.xpath("#{TABLE}tbody[1]/tr")
            return [rows, api, dates] if headers.first == "Model" && api && dates && rows.any?

            raise Error, "Mistral retired models table not found or changed"
          end

          def card(cells, api, dates)
            link = cells.first&.at_css("a[href^='/models/']") or raise Error, "Mistral retired row without a model card"
            retires = cells[dates]&.text.to_s.scan(DATE)[1]
            [link["href"].split("/").last, cells[api].text.strip, Date.strptime(retires, "%m/%d/%Y")] if retires
          end
        end
      end
    end
  end
end
