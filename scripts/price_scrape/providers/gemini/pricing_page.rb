# frozen_string_literal: true

require_relative "../base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Gemini < Base
        class PricingPage
          Section = Data.define(:model_ids, :tabs, :same_as, :notes)

          SECTION_START = /^(?=## )/
          MODEL_ID_LINES = /^[ \t]*\*\[`.*?(?=\n[ \t]*\n|\z)/m
          MODEL_ID = /\[`([^`]+)`\]/
          PRICING_BLOCK = %r{\{% tabs %\}.*?\{% /tabs %\}|\{% table %\}.*?\{% /table %\}}m
          TAB = %r{\{% tab title="([^"]+)" %\}(.*?)\{% /tab %\}}m
          TABLE = %r{\{% table %\}(.*?)\{% /table %\}}m
          ROW_BREAK = /^[ \t]*---[ \t]*$/
          CELL = /\A[ \t]*\* /
          LINE_BREAK = /(?: {2,}|[ \t]*\\+)\n|\n[ \t]*\n/
          TAG = /\{%.*?%\}/m
          LINK = /\[([^\]]*)\]\([^)]*\)/
          TEXT_PRICED_AS = /Text input and output\s+is priced the same as/
          PRICED_AS_ANCHOR = /#{TEXT_PRICED_AS}\s*\[[^\]]*\]\([^)#]*#([^)\s]+)\)/

          def initialize(markdown)
            @markdown = markdown.to_s
          end

          def sections
            texts = @markdown.split(SECTION_START).select { |text| text.start_with?("## ") }
            raise Error, "Gemini pricing sections not found" if texts.empty?

            texts.map { |text| section(text) }
          end

          private

          def section(text)
            block = text.match(PRICING_BLOCK)
            return Section.new(model_ids: [], tabs: {}, same_as: nil, notes: "") unless block

            Section.new(
              model_ids: block.pre_match[MODEL_ID_LINES].to_s.scan(MODEL_ID).flatten,
              tabs: tabs(block[0]),
              same_as: same_as(block.pre_match.delete("*")),
              notes: block.post_match
            )
          end

          def tabs(block)
            return { "Standard" => rows(block[TABLE, 1]) } unless block.start_with?("{% tabs %}")

            block.scan(TAB).each_with_object({}) do |(title, body), tabs|
              table = body[TABLE, 1]
              tabs[title] = rows(table) if table
            end
          end

          def rows(table)
            _header, *body = table.split(ROW_BREAK)
            body.each_with_object({}) do |row, rows|
              cells = cells(row)
              rows[cells[0]] = cells[2] if cells.size >= 3
            end
          end

          def cells(row)
            cells = row.lines.each_with_object([]) do |line, markdoc|
              if line.match?(CELL)
                markdoc << line.sub(CELL, "")
              elsif markdoc.any?
                markdoc[-1] += line
              end
            end
            cells.map { |cell| plain_text(cell) }
          end

          def plain_text(markdoc)
            lines = markdoc.gsub(TAG, "").gsub(LINK, '\1').split(LINE_BREAK)
            lines.map { |line| line.gsub(/\s+/, " ").strip }.reject(&:empty?).join("\n")
          end

          def same_as(prose)
            prose[PRICED_AS_ANCHOR, 1].to_s if prose.match?(TEXT_PRICED_AS)
          end
        end
      end
    end
  end
end
