# frozen_string_literal: true

require "date"

require_relative "../base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Openai < Base
        module DeprecatedModels
          SOURCE_URL = "https://developers.openai.com/api/docs/deprecations"
          SHUTDOWN_HEADING = "SHUTDOWN DATE"
          MODEL_HEADING = "MODEL"
          REPLACEMENT_HEADING = "REPLACEMENT"
          MODEL_SEPARATOR = /[|,]/
          HYPHENS = "‐‑‒–—"
          MODEL_ID = %r{\A[a-z0-9][a-z0-9_.-]*(?:/[a-z0-9][a-z0-9_.-]*)*\z}

          class << self
            def call(doc, scraped_on:)
              tables = doc.css("table").select { |table| headings(table).any? { |h| h.include?(SHUTDOWN_HEADING) } }
              raise Error, "OpenAI deprecations tables not found" if tables.empty?

              tables.flat_map { |table| shutdown_models(table, scraped_on: scraped_on) }.uniq
            end

            private

            def shutdown_models(table, scraped_on:)
              headings = headings(table)
              shutdown_index = headings.find_index { |heading| heading.include?(SHUTDOWN_HEADING) }
              model_index = headings.find_index do |heading|
                heading.include?(MODEL_HEADING) && !heading.include?(REPLACEMENT_HEADING)
              end
              return [] unless model_index

              table.css("tbody tr").flat_map do |row|
                cells = row.css("td").map { |cell| normalize(cell.text) }
                next [] if cells.size <= [shutdown_index, model_index].max

                retired_models(cells[model_index], shutdown_on: date(cells[shutdown_index]), scraped_on: scraped_on)
              end
            end

            def retired_models(cell, shutdown_on:, scraped_on:)
              return [] unless shutdown_on && shutdown_on <= scraped_on

              cell.split(MODEL_SEPARATOR).map(&:strip).select { |model_id| model_id.match?(MODEL_ID) }
            end

            def date(text)
              Date.parse(text)
            rescue Date::Error
              nil
            end

            def headings(table)
              table.css("thead th").map { |th| normalize(th.text).upcase }
            end

            def normalize(text)
              text.to_s.gsub(/\s+/, " ").strip.tr(HYPHENS, "-" * HYPHENS.length)
            end
          end
        end
      end
    end
  end
end
