# frozen_string_literal: true

require "date"
require "nokogiri"
require "time"

require_relative "base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Deepseek < Base
        source_url "https://api-docs.deepseek.com/quick_start/pricing"
        min_models 2
        max_price 100.0
        anchors "deepseek-flash"

        PRICE_ROWS = {
          "(CACHE HIT)" => "cache_read_input", "(CACHE MISS)" => "input", "1M OUTPUT TOKENS" => "output"
        }.freeze
        TIERS = { "PEAK" => "", "OFF-PEAK" => "off_peak_" }.freeze
        MARKER = /\((\d+)\)\z/
        MODEL_ID = /\A[a-z0-9][a-z0-9.-]*\z/
        PRICE = /\A\$(\d+(?:\.\d+)?)\z/
        LEGACY = /legacy names (.+?) are still accepted, .* billed at the \w+ price/
        PEAK = /Peak hours are (.+?) UTC, (\w+) through (\w+), .*All other hours are off-peak/
        HOURS = /\A(\d{2}):(\d{2}) - (\d{2}):(\d{2})\z/

        def call(html:, source_url: self.class.source_url, scraped_at: Time.now.utc.iso8601)
          doc = Nokogiri::HTML(html)
          table = doc.css("table").find { |candidate| candidate.text.include?("PRICING") }
          raise Error, "DeepSeek pricing table not found" unless table

          columns = model_columns(table)
          windows = off_peak_windows(footnote(doc) { |text| text.include?("Peak hours are") })
          models = columns.keys.zip(column_prices(table, columns.size)).to_h do |model, fields|
            [model, fields.merge(Pricing::Registry::OFF_PEAK_WINDOWS_KEY => windows)]
          end
          legacy = columns.filter_map { |model, marker| legacy_models(doc, marker, models.fetch(model)) if marker }
          models = models.merge(*legacy)
          validate!(models)
          Result.new(source_url:, scraped_at:, models:, deprecated_models: [], service_charges: {})
        end

        private

        def model_columns(table)
          row = table.css("tr").find { |candidate| candidate.at_css("td")&.text&.strip == "MODEL" }
          raise Error, "DeepSeek model row not found" unless row

          row.css("td").drop(1).to_h do |cell|
            name = cell.text.strip
            [name.sub(MARKER, ""), name[MARKER, 1]]
          end
        end

        def column_prices(table, count)
          label = nil
          prices = Array.new(count) { {} }
          table.css("tr").map { |row| row.css("td").map { |cell| cell.text.strip } }.each do |cells|
            tier = cells.index { |cell| TIERS.key?(cell) } or next
            label = cells[tier - 1] unless tier.zero?
            store(prices, "#{TIERS.fetch(cells[tier])}#{row_field(label.to_s)}", cells.last(count))
          end
          return prices if prices.all? { |fields| fields.size == PRICE_ROWS.size * TIERS.size }

          raise Error, "DeepSeek peak and off-peak input, cache hit and output prices not found"
        end

        def row_field(label)
          PRICE_ROWS.find { |suffix, _| label.end_with?(suffix) }&.last or
            raise Error, "DeepSeek price row #{label.inspect} not understood"
        end

        def store(prices, field, cells)
          raise Error, "DeepSeek #{field} prices listed twice" if prices.first.key?(field)

          prices.zip(cells) { |fields, cell| fields[field] = price(cell) }
        end

        def price(cell)
          Float(cell[PRICE, 1] || raise(Error, "DeepSeek price #{cell.inspect} not understood"))
        end

        def footnote(doc, &)
          paragraph = doc.css("p").map { |candidate| candidate.text.gsub(/\s+/, " ").strip }.find(&)
          paragraph or raise Error, "DeepSeek pricing footnote not found"
        end

        def legacy_models(doc, marker, fields)
          names = footnote(doc) { |text| text.start_with?("(#{marker})") }[LEGACY, 1].to_s.split(/,?\s+and\s+|,\s*/)
          raise Error, "DeepSeek footnote (#{marker}) names no legacy models" unless names.any? && names.all?(MODEL_ID)

          names.to_h { |name| [name, fields] }
        end

        def off_peak_windows(text)
          hours, from, to = text.match(PEAK)&.captures
          days = [from, to].map { |day| Date::DAYNAMES.index(day) }
          raise Error, "DeepSeek peak hours not understood: #{text}" unless hours && days.all? && days[0] <= days[1]

          peak_days = (days[0]..days[1]).map { |day| day.zero? ? 7 : day }
          windows = [{ "weekdays" => peak_days, "hours_utc" => off_peak_hours(hours.split(" and ")) }]
          other_days = (1..7).to_a - peak_days
          other_days.empty? ? windows : windows << { "weekdays" => other_days, "hours_utc" => ["00:00-24:00"] }
        end

        def off_peak_hours(ranges)
          peak = ranges.map { |range| peak_minutes(range) }.sort
          gaps = [[0, 0], *peak, [1440, 1440]].each_cons(2).map { |(_, from), (to, _)| [from, to] }
          raise Error, "DeepSeek peak hours #{ranges.join(' and ')} overlap" if gaps.any? { |from, to| from > to }

          gaps.reject { |from, to| from == to }.map { |range| range.map { |minute| clock(minute) }.join("-") }
        end

        def peak_minutes(range)
          clocks = Array(range.match(HOURS)&.captures).each_slice(2).map { |hour, min| (hour.to_i * 60) + min.to_i }
          return clocks if clocks.size == 2 && clocks.first < clocks.last

          raise Error, "DeepSeek peak hours #{range.inspect} not understood"
        end

        def clock(minute) = format("%<hour>02d:%<minute>02d", hour: minute / 60, minute: minute % 60)
      end
    end
  end
end
