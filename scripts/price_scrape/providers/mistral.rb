# frozen_string_literal: true

require "date"
require "nokogiri"
require "time"

require_relative "litellm"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Mistral < Litellm
        source_url SOURCE_URL
        min_models 10
        max_price 1000.0
        anchors "mistral-large-latest", "mistral-medium-latest", "mistral-small-latest"

        PRICING_SOURCE_URL = "https://docs.mistral.ai/inference/pricing"
        MODELS_SOURCE_URL = "https://docs.mistral.ai/models"
        TIER_SOURCES = {
          "batch" => ["https://docs.mistral.ai/studio/batch-processing.md", /at a (\d+)% discount/],
          "priority" => ["https://docs.mistral.ai/inference/priority-tier.md",
                         /multiplier is ([\d.]+)x standard list pricing/],
          "data_residency" => ["https://docs.mistral.ai/inference/regional-inference.md",
                               /billed at \*\*([\d.]+)[x×] standard list pricing/]
        }.freeze
        SOURCE_URLS = [source_url, MODELS_DEV_URL, PRICING_SOURCE_URL, MODELS_SOURCE_URL,
                       *TIER_SOURCES.values.map(&:first)].freeze
        PRICE_COLUMNS = { "Input" => "input", "Cached input" => "cache_read_input", "Output" => "output" }.freeze
        REQUIRED = {
          "chat" => %w[input output], "responses" => %w[input output], "embedding" => %w[input], "ocr" => %w[ocr_page],
          "audio_transcription" => %w[transcription_minute], "audio_speech" => %w[text_to_speech_character],
          "moderation" => %w[input]
        }.freeze
        MODEL_CARD = %r{\Ahttps://docs\.mistral\.ai/models/(?:model-cards/)?(?<card>[a-z0-9-]+)\z}
        PRICE = %r{\A(?:\$(?<amount>\d+(?:\.\d+)?)(?: (?<unit>/1000 Pages|/Min|/M Chars))?|(?<free>Free))\z}
        UNIT_COLUMNS = {
          "/1000 Pages" => %w[input ocr_page], "/Min" => %w[input transcription_minute],
          "/M Chars" => %w[output text_to_speech_character]
        }.freeze
        RETIRED_TABLE = "//h3[normalize-space()='Deprecated & retired models']/following::"
        CARD_NAMES = /\\"names\\":\[([^\]]*)\]/
        CARD_MINUTE_PRICE = %r{\\"price\\":(\d+(?:\.\d+)?),\\"denominator\\":\\"/Min\\"}
        DATE = %r{\d{1,2}/\d{1,2}/\d{4}}

        def self.followup_urls(pages)
          cards = pages.fetch(MODELS_SOURCE_URL).scan(%r{href="/models/([a-z0-9-]+)"}).flatten.uniq
          cards.map { |card| "#{MODELS_SOURCE_URL}/#{card}" }
        end

        def call(html:, source_url: self.class.source_url, scraped_at: Time.now.utc.iso8601)
          @listed = listed_prices(Nokogiri::HTML(html.fetch(PRICING_SOURCE_URL)))
          @cards_by_stem = cards_by_stem(@listed.keys)
          names = self.class.followup_urls(html).to_h { |url| [url.split("/").last, card_names(html.fetch(url), url)] }
          @cards_by_name = names.slice(*@listed.keys).flat_map { |card, ids| ids.product([card]) }.to_h
          retired, ambiguous = retirement(html.fetch(MODELS_SOURCE_URL), names, Date.parse(scraped_at))
          models = official_models(self.class.parse_json(html.fetch(SOURCE_URL)))
          rows = self.class.confirmed_rows("mistral", html, models, scraped_at)
          rows &&= with_card_minutes(with_card_names(rows, names, models, html), names, html)
          models = with_tiers(models.merge(rows.to_h.except(*retired, *ambiguous)), html)
          validate!(models.except(*retired))
          notes = (rows.to_h.keys & ambiguous).map do |id|
            "- `mistral/#{id}`: named on both a retired and a current Mistral model card; not written"
          end
          notes << "- `mistral`: models.dev was unreachable or invalid, so no LiteLLM-only row was written" unless rows
          Result.new(source_url:, scraped_at:, models:, deprecated_models: retired, service_charges: {}, notes:)
        end

        private

        def with_card_names(rows, names, models, html)
          shared = names.values.flatten.tally.select { |_id, cards| cards > 1 }.keys
          listed = JSON.parse(html.fetch(MODELS_DEV_URL)).dig("mistral", "models") || {}
          names.values.each_with_object(rows.dup) do |ids, named|
            own = ids - shared
            row = rows.values_at(*own).compact.first
            (own - models.keys).each { |id| named[id] ||= row if models_dev_agrees?(listed[id], row) } if row
          end
        end

        def models_dev_agrees?(listing, row)
          theirs = listing&.dig("cost")&.values_at("input", "output") or return true
          row.values_at("input", "output").zip(theirs).none? { |pair| self.class.differ?(*pair.map(&:to_f)) }
        end

        def with_card_minutes(rows, names, html)
          names.each_with_object(rows.dup) do |(card, ids), priced|
            minute = html.fetch("#{MODELS_SOURCE_URL}/#{card}")[CARD_MINUTE_PRICE, 1] or next
            (ids & rows.keys).each { |id| priced[id] = rows[id].merge("transcription_minute" => Float(minute)) }
          end
        end

        def official_models(catalogue)
          catalogue.each_with_object({}) do |(key, entry), collected|
            required = entry.is_a?(Hash) && REQUIRED[entry["mode"]]
            next unless key.start_with?("mistral/") && required

            id = key.delete_prefix("mistral/")
            fields = extract_fields(id, entry)
            collected[id] = fields if required.all? { |field| fields.key?(field) }
          end
        end

        def retirement(page, names, today)
          retired = retired_cards(page, today)
          ids = retired.flat_map { |card, api| [api, *names.fetch(card)] }.reject(&:empty?).uniq
          live = names.except(*retired.map(&:first)).values.flatten
          [ids - live, ids & live]
        end

        def retired_cards(page, today)
          doc = Nokogiri::HTML(page)
          headers = doc.xpath("#{RETIRED_TABLE}thead[1]/tr/th").map { |header| header.text.strip }
          api = headers.index("API")
          dates = headers.index("DeprecationRetirement")
          rows = doc.xpath("#{RETIRED_TABLE}tbody[1]/tr")
          unless headers.first == "Model" && api && dates && rows.any?
            raise Error, "Mistral retired models table not found or changed"
          end

          rows.filter_map do |row|
            cells = row.css("td")
            card = cells.first&.at_css("a[href^='/models/']") or raise Error, "Mistral retired row without a model card"
            retires = cells[dates]&.text.to_s.scan(DATE)[1]
            next unless retires && Date.strptime(retires, "%m/%d/%Y") <= today

            [card["href"].split("/").last, cells[api].text.strip]
          end
        end

        def card_names(page, url)
          list = page[CARD_NAMES, 1] or raise Error, "Mistral model card #{url} lists no API names"
          list.scan(/\\"([^\\"]+)\\"/).flatten
        end

        def with_tiers(models, html)
          tiers = TIER_SOURCES.to_h do |tier, (url, pattern)|
            factor = documented_factor(html.fetch(url), pattern, tier)
            [tier, tier == "batch" ? 1 - (factor / 100) : factor]
          end
          tiers["priority_data_residency"] = tiers.fetch("priority") * tiers.fetch("data_residency")
          models.transform_values do |fields|
            applied = fields.key?("output") ? tiers : tiers.except("priority", "priority_data_residency")
            applied.reduce(fields) { |priced, (tier, factor)| priced.merge(tier_prices(fields, tier, factor)) }
          end
        end

        def extract_fields(id, entry)
          stem = id[/\A(.+)-(?:latest|\d{4})\z/, 1]
          latest_stem = stem.delete_prefix("mistral-") if id.end_with?("-latest")
          card = @cards_by_name[id] || MODEL_CARD.match(entry["source"].to_s)&.[](:card) || @cards_by_stem[stem]
          card ||= @cards_by_stem[latest_stem]
          @listed.fetch(card, {})
        end

        def cards_by_stem(cards)
          cards.group_by { |card| card.sub(/-\d{2}-\d{2}\z/, "").split("-").grep_v(/\A\d+\z/).join("-") }
               .filter_map { |stem, group| [stem, group.first] if group.one? }.to_h
        end

        def listed_prices(doc)
          doc.css(".sr-only").remove
          doc.css("table").each_with_object({}) do |table, listed|
            fields = table.css("th").map { |header| PRICE_COLUMNS[header.text.strip] }
            table.css("tr").each do |row|
              link = row.at_css("a[href^='/models/']") or next
              prices = fields.zip(row.css("td")).filter_map { |field, cell| listed_price(field, cell) }.to_h
              raise Error, "Mistral pricing row for #{link['href']} has no price the scraper reads" if prices.empty?

              listed[link["href"].delete_prefix("/models/")] = prices
            end
          end
        end

        def listed_price(field, cell)
          price = PRICE.match((cell&.at_css("ins") || cell)&.text.to_s.strip)
          column, dimension = UNIT_COLUMNS.fetch(price[:unit], [field, field]) if price
          [dimension, price[:free] ? 0.0 : Float(price[:amount])] if field && column == field
        end
      end
    end
  end
end
