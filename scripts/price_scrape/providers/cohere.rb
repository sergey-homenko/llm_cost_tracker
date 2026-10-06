# frozen_string_literal: true

require "json"
require "strscan"
require "time"

require_relative "litellm"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Cohere < Litellm
        source_url "https://cohere.com/pricing"
        min_models 7
        max_price 100.0

        MODELS_SOURCE_URL = "https://docs.cohere.com/docs/models.md"
        SOURCE_URLS = [source_url, MODELS_SOURCE_URL, SOURCE_URL, MODELS_DEV_URL].freeze
        FLIGHT_CHUNK = /self\.__next_f\.push\(\[1,("(?:[^"\\]|\\.)*")\]\)/
        FIELDS = {
          "1M tokens Input" => "input", "1M tokens Output" => "output", "1M tokens Cost" => "input",
          "1K searches Cost" => "rerank_search_unit", "1K pages Cost" => "ocr_page"
        }.freeze
        FAQ_PRICE = %r{
          \A(?<name>.+?)\s(?:pricing\sis|models\s\((?<sizes>[^)]+)\)\son\sthe\sAPI\sare\scharged\sat)
          \s\$(?<input>\d+(?:\.\d+)?)/1M\stokens\sfor\sinput\sand\s\$(?<output>\d+(?:\.\d+)?)/1M\stokens\sfor\soutput\b
        }x
        RELEASE_SUFFIX = /-\d+-\d+\z/
        STATUS = /\A(?:Live\z|Deprecated\b|Retired\b)/

        def call(html:, source_url: self.class.source_url, scraped_at: Time.now.utc.iso8601)
          @listed = listed_ids(html.fetch(MODELS_SOURCE_URL))
          retired = @listed.select { |_id, status| status == "Retired" }.keys
          official = official_models(html.fetch(self.class.source_url)).except(*retired)
          rows = self.class.confirmed_rows("cohere", html, official, scraped_at)
          models = official.reject { |_id, fields| fields.empty? }.merge(rows.to_h.except(*retired))
          validate!(models)
          notes = rows ? [] : ["- `cohere`: models.dev was unreachable or invalid, so no LiteLLM-only row was written"]
          Result.new(source_url:, scraped_at:, models:, deprecated_models: retired, service_charges: {}, notes:)
        end

        private

        def official_models(page)
          rows = flight_rows(page)
          cards = section(rows, "web3PricingSection").fetch("pricingGroups").flat_map { |group| group["models"].to_a }
          prices = cards.filter_map { |card| (fields = card_prices(card)) && [api_id(card.fetch("modelName")), fields] }
          (prices + faq_prices(section(rows, "web3AccordionSection"))).each_with_object({}) do |(id, fields), models|
            raise Error, "Cohere prices #{id} twice" if models.key?(id)

            models[id] = fields
          end
        end

        def flight_rows(page)
          flight = StringScanner.new(page.scan(FLIGHT_CHUNK).map { |(chunk)| JSON.parse(chunk) }.join.b)
          rows = []
          while flight.skip(/\h*:/)
            if flight.scan(/T(\h+),/)
              flight.pos += flight[1].hex
            else
              rows << flight.scan_until(/\n/).to_s.force_encoding(Encoding::UTF_8)
            end
          end
          rows
        end

        def section(rows, type)
          row = rows.find { |candidate| candidate.include?(%("_type":"#{type}")) } or
            raise Error, "Cohere #{type} not found"
          hashes(JSON.parse(row)).find { |node| node["_type"] == type }
        end

        def hashes(node)
          case node
          when Hash then [node, *hashes(node.values)]
          when Array then node.flat_map { |child| hashes(child) }
          else []
          end
        end

        def card_prices(card)
          pricing, *more = card["pricings"]
          name = card.fetch("modelName")
          raise Error, "Cohere lists several prices for #{name}" if more.any?
          return unless pricing
          return {} if card["per"] == "Free" && pricing.values_at("inputPrice", "outputPrice") == [0, 0]

          unit = pricing["overridePer"] || card["per"]
          %w[input output].each_with_object({}) do |side, fields|
            price = pricing["#{side}Price"] or next
            label = pricing["#{side}Label"]
            field = FIELDS["#{unit} #{label}"] if price.is_a?(Numeric)
            raise Error, "Cohere #{name} price #{price.inspect} per #{unit} (#{label}) not understood" unless field

            fields[field] = price.to_f
          end
        end

        def faq_prices(faq)
          blocks = hashes(faq).select { |node| node["_type"] == "block" }
          blocks.map { |block| block["children"].to_a.map { |child| child["text"] }.join }
                .select { |text| text.include?("/1M tokens") }.flat_map do |text|
            match = FAQ_PRICE.match(text) or raise Error, "Cohere FAQ price not understood: #{text}"
            fields = { "input" => Float(match[:input]), "output" => Float(match[:output]) }
            names = match[:sizes]&.split(/,\s*|\s+and\s+/)&.map { |size| "#{match[:name]} #{size}" } || [match[:name]]
            names.map { |name| [api_id(name, live: false), fields] }
          end
        end

        def listed_ids(page)
          ids = page.split(/^(?=\| Model Name )/).drop(1).each_with_object({}) do |table, listed|
            header, _rule, *rows = table.lines.take_while { |line| line.start_with?("|") }
                                        .map { |line| line.split("|").drop(1).map(&:strip) }
            next unless header.include?("Description")

            column = header.index("Status")
            rows.each do |cells|
              id = cells.first[/\A`([^`]+)`\z/, 1] or
                raise Error, "Cohere models overview row #{cells.first.inspect} names no API id"
              listed[id] = ((column && cells[column]) || "Live")[STATUS] or
                raise Error, "Cohere model status #{cells[column].inspect} not understood"
            end
          end
          ids.any? ? ids : raise(Error, "Cohere models overview lists no API ids")
        end

        def api_id(name, live: true)
          key = name_key(name)
          found = @listed.select do |id, _status|
            [id, id.sub(RELEASE_SUFFIX, "")].any? { |listed| name_key(listed).last(key.size) == key }
          end
          ids = live && found.size > 1 ? found.select { |_id, status| status == "Live" }.keys : found.keys
          return ids.first if ids.one?

          raise Error, "no single API id on Cohere's models overview for #{name.inspect}: #{found.keys.inspect}"
        end

        def name_key(text)
          text.downcase.gsub("+", " plus").split(/[\s-]+/).map { |part| part.sub(/\Av(?=\d)/, "").delete_suffix(".0") }
        end
      end
    end
  end
end
