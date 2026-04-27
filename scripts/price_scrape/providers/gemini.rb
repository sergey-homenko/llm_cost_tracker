# frozen_string_literal: true

require "nokogiri"
require "time"

module LlmCostTracker
  module PriceScrape
    module Providers
      class Gemini
        SOURCE_URL = "https://ai.google.dev/gemini-api/docs/pricing"
        MIN_MODELS_EXPECTED = 5
        MAX_PRICE_PER_MTOK = 1000.0

        Result = Data.define(:source_url, :scraped_at, :models, :deprecated_models)

        class Error < StandardError; end

        def call(html:, source_url: SOURCE_URL, scraped_at: Time.now.utc.iso8601)
          doc = Nokogiri::HTML(html.to_s)
          models = extract_models(doc)
          validate!(models)
          Result.new(
            source_url: source_url,
            scraped_at: scraped_at,
            models: models,
            deprecated_models: []
          )
        end

        private

        def extract_models(doc)
          article = find_article(doc)
          raise Error, "Gemini pricing article body not found" unless article

          pair_sections(article).each_with_object({}) do |(model_id, tabs), models|
            next unless model_id

            standard_table = find_standard_table(tabs)
            next unless standard_table

            fields = extract_text_pricing(standard_table)
            models[model_id] = fields if fields
          end
        end

        def find_article(doc)
          doc.at_xpath(
            "//div[contains(concat(' ', normalize-space(@class), ' '), ' devsite-article-body ')]"
          )
        end

        def pair_sections(article)
          current_model_id = nil
          article.children.each_with_object([]) do |child, pairs|
            next if child.text?
            next unless child.respond_to?(:css)

            if child["class"]&.include?("models-section")
              raw_id = child.at_css("div.heading-group code")&.text&.strip
              current_model_id = normalize_model_id(raw_id)
            elsif child["class"]&.include?("ds-selector-tabs")
              pairs << [current_model_id, child]
              current_model_id = nil
            end
          end
        end

        def find_standard_table(tabs)
          tabs.css("section").find { |sec| sec.at_css("h3")&.text&.strip == "Standard" }&.at_css("table")
        end

        def extract_text_pricing(table)
          rows = parse_table(table)
          input_key = rows.keys.find { |k| k.start_with?("Input price") }
          output_key = rows.keys.find { |k| k.start_with?("Output price") }
          return nil unless input_key && output_key

          {
            "input" => parse_price(rows[input_key]),
            "output" => parse_price(rows[output_key])
          }
        end

        def parse_table(table)
          price_column_index = paid_tier_column_index(table)
          return {} unless price_column_index

          table.css("tbody tr").each_with_object({}) do |tr, acc|
            cells = tr.css("td")
            next if cells.size <= price_column_index

            key = normalize_text(cells[0].text)
            value = normalize_text(cells[price_column_index].text)
            next if key.empty? || value.empty?

            acc[key] = value
          end
        end

        def paid_tier_column_index(table)
          headers = table.css("thead th").map { |th| normalize_text(th.text).downcase }
          headers.find_index { |header| header.include?("paid tier") && header.include?("per 1m tokens") } ||
            headers.find_index { |header| header.include?("paid tier") }
        end

        def normalize_text(text)
          text.to_s.gsub(/\s+/, " ").strip
        end

        def normalize_model_id(raw_id)
          id = raw_id.to_s.split(/\s+and\s+|\s*,\s*/).first&.strip.to_s
          return nil unless id.match?(/\Agemini-/)
          return nil if id.include?("-preview")
          return nil if id.match?(/-(?:tts|image|embedding|live|robotics|computer|native-audio)/)
          return nil unless id.match?(/\Agemini-\d+(?:\.\d+)?-(?:pro|flash(?:-lite)?)/)

          id
        end

        def parse_price(text)
          match = text.to_s.match(/\$\s*(\d+(?:\.\d+)?)/)
          raise Error, "unable to parse price #{text.inspect}" unless match

          Float(match[1])
        end

        def validate!(models)
          if models.size < MIN_MODELS_EXPECTED
            raise Error, "expected at least #{MIN_MODELS_EXPECTED} models, parsed #{models.size}"
          end

          models.each do |model_id, fields|
            fields.each do |field, value|
              next if value.is_a?(Float) && value.positive? && value < MAX_PRICE_PER_MTOK

              raise Error, "invalid price for #{model_id}.#{field}: #{value.inspect}"
            end
          end
        end
      end
    end
  end
end
