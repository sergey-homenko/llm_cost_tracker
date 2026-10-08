# frozen_string_literal: true

require_relative "../base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Groq < Base
        class Table
          attr_reader :headers

          def self.all(doc) = doc.css("table").map { |node| new(node) }

          def self.text(value) = value.to_s.gsub(/\s+/, " ").strip

          def initialize(node)
            @node = node
            @headers = node.css("thead th").map { |th| Table.text(th.text) }
          end

          def header?(needle) = headers.any? { |header| header.upcase.include?(needle) }

          def column(needle, excluding: nil)
            index = headers.find_index do |header|
              header.upcase.include?(needle) && !(excluding && header.upcase.include?(excluding))
            end
            raise Error, "Groq pricing column #{needle.inspect} not found in #{headers.inspect}" unless index

            index
          end

          def rows(*columns)
            @node.css("tbody tr").filter_map do |row|
              cells = row.css("td")
              [row, cells] if cells.size > columns.max
            end
          end
        end
      end
    end
  end
end
