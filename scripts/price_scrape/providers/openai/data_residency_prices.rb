# frozen_string_literal: true

require "date"
require "yaml"

require_relative "../base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Openai < Base
        class DataResidencyPrices
          ELIGIBILITY_URL = "https://developers.openai.com/api/docs/guides/your-data.md"
          CHANGELOG_URL = "https://developers.openai.com/api/docs/changelog.md"
          SOURCE_URLS = [ELIGIBILITY_URL, CHANGELOG_URL].freeze
          RELEASES_FILE = "scripts/price_scrape/providers/openai/data_residency_releases.yml"
          RELEASES = YAML.safe_load_file(File.expand_path("../../../../#{RELEASES_FILE}", __dir__)).freeze
          UPLIFT = /charged a (\d+)% uplift for models released on or after (\w+ \d{1,2}, \d{4})/
          SUPPORT_TABLE = /^#### API Endpoint, tool and model support$(.*?)(?=^#|\z)/m
          SUPPORT_COLUMNS = ["Processing regions", "Supported models"].freeze
          DAY_HEADING = /\A### ((?:#{Date::ABBR_MONTHNAMES.compact.join('|')})\w* \d{1,2})\s*\z/
          SNAPSHOT_DATE = /-(\d{4}-\d{2}-\d{2})\z/
          TIERS = %w[batch flex fast ultrafast].freeze
          PRICE_FIELD = /\A(above_context_)?((?:#{TIERS.join('|')})_)?(input|output|cache_(?:read|write)_input)\z/

          def self.call(models, pages) = new(pages).call(models)

          def initialize(pages)
            page = pages.fetch(ELIGIBILITY_URL)
            @factor, @cutoff = uplift(page)
            @listed = processing_model_ids(page).group_by { |id| id.sub(SNAPSHOT_DATE, "") }
            unless @listed.keys.intersect?(RELEASES.fetch("released_on_or_after_cutoff"))
              raise Error, "no OpenAI model found eligible for data residency pricing"
            end

            @mentioned = first_mentions(pages.fetch(CHANGELOG_URL))
          end

          def call(models)
            notes = []
            priced = models.to_h do |model_id, fields|
              residency = uplifted?(model_id.sub(SNAPSHOT_DATE, "")) { |note| notes << note }
              [model_id, residency ? fields.merge(data_residency_prices(fields)) : fields]
            end
            [priced, notes.uniq]
          end

          private

          def uplift(page)
            text = page.gsub(/\[([^\]]*)\]\([^)]*\)/, '\1').gsub(/\s+/, " ")
            percent, date = text.match(UPLIFT)&.captures
            raise Error, "OpenAI data residency uplift not found in its data controls guide" unless percent

            [1 + (Float(percent) / 100), Date.parse(date)]
          end

          def uplifted?(model_id)
            eligible = @listed.key?(model_id)
            return eligible if RELEASES.fetch("released_on_or_after_cutoff").include?(model_id)
            return false if RELEASES.fetch("released_before_cutoff").include?(model_id)
            return eligible if dated_on_or_after_cutoff?(model_id)

            yield "- `openai/#{model_id}`: eligible #{eligible ? 'yes' : 'no'}, " \
                  "earliest snapshot #{earliest_snapshot(model_id) || 'none'}, " \
                  "first changelog mention #{@mentioned[model_id] || 'none'}; " \
                  "add it to released_on_or_after_cutoff or released_before_cutoff in #{RELEASES_FILE}"
            false
          end

          def dated_on_or_after_cutoff?(model_id)
            dates = [earliest_snapshot(model_id), @mentioned[model_id]].compact
            dates.any? && dates.min >= @cutoff
          end

          def earliest_snapshot(model_id)
            snapshot = @listed.fetch(model_id, []).filter_map { |id| id[SNAPSHOT_DATE, 1] }.min
            snapshot && Date.parse(snapshot)
          end

          def processing_model_ids(page)
            header, *rows = markdown_rows(page[SUPPORT_TABLE, 1].to_s)
            processing, models = SUPPORT_COLUMNS.map { |title| header.to_a.index { |cell| cell.include?(title) } }
            raise Error, "OpenAI data residency model table not found" unless processing && models

            rows.reject { |cells| cells[processing].to_s.match?(/\A(?:None|-*)\z/) }
                .flat_map { |cells| cells[models].to_s.scan(/`([^`]+)`/).flatten }
          end

          def markdown_rows(section)
            section.lines.filter_map { |line| line.split("|")[1..-2].map(&:strip) if line.start_with?("|") }
          end

          def first_mentions(changelog)
            year = nil
            day = nil
            changelog.each_line.with_object({}) do |line, mentioned|
              year = line[/\A## \w+, (\d{4})\s*\z/, 1] || year
              heading = line[DAY_HEADING, 1]
              day = Date.parse("#{heading} #{year}") if heading && year
              next unless day

              line.scan(/Model: ([\w.-]+)|`([\w.-]+)`/).flatten.compact.each do |id|
                model_id = id.sub(SNAPSHOT_DATE, "")
                mentioned[model_id] = [mentioned[model_id], day].compact.min
              end
            end
          end

          def data_residency_prices(fields)
            fields.each_with_object({}) do |(field, value), prices|
              key = data_residency_field(field.to_s)
              prices[key] = (value * @factor).round(6) if key
            end
          end

          def data_residency_field(field)
            return "data_residency_#{field}" if field == "transcription_minute"

            field.sub(PRICE_FIELD, '\1\2data_residency_\3') if field.match?(PRICE_FIELD)
          end
        end
      end
    end
  end
end
