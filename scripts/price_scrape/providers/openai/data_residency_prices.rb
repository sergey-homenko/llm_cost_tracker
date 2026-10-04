# frozen_string_literal: true

require "date"

require_relative "../base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Openai < Base
        module DataResidencyPrices
          ELIGIBILITY_URL = "https://developers.openai.com/api/docs/guides/your-data.md"
          CHANGELOG_URL = "https://developers.openai.com/api/docs/changelog.md"
          SOURCE_URLS = [ELIGIBILITY_URL, CHANGELOG_URL].freeze
          UPLIFT = /charged a (\d+)% uplift for models released on or after (\w+ \d{1,2}, \d{4})/
          SUPPORT_TABLE = /^#### API Endpoint, tool and model support$(.*?)(?=^#|\z)/m
          DAY_HEADING = /\A### ((?:#{Date::ABBR_MONTHNAMES.compact.join('|')})\w* \d{1,2})\s*\z/
          SNAPSHOT_DATE = /-(\d{4}-\d{2}-\d{2})\z/
          TIERS = %w[batch flex fast ultrafast].freeze
          TIER_FIELD = /\A(#{TIERS.join('|')})_(.+)\z/
          PRICE_FIELD = /\A(?:above_context_)?(?:(?:#{TIERS.join('|')})_)?(?:input|output|cache_(?:read|write)_input)\z/

          class << self
            def call(models, pages)
              page = pages.fetch(ELIGIBILITY_URL)
              factor, cutoff = uplift(page)
              eligible = eligible_models(page, pages.fetch(CHANGELOG_URL), cutoff)
              raise Error, "no OpenAI model found eligible for data residency pricing" if eligible.empty?

              models.to_h do |model_id, fields|
                [model_id, eligible.include?(model_id) ? fields.merge(data_residency_prices(fields, factor)) : fields]
              end
            end

            private

            def uplift(page)
              text = page.gsub(/\[([^\]]*)\]\([^)]*\)/, '\1').gsub(/\s+/, " ")
              percent, date = text.match(UPLIFT)&.captures
              raise Error, "OpenAI data residency uplift not found in its data controls guide" unless percent

              [1 + (Float(percent) / 100), Date.parse(date)]
            end

            def eligible_models(page, changelog, cutoff)
              released, mentioned = changelog_dates(changelog)
              raise Error, "OpenAI model release dates not found in its changelog" if released.empty?

              processing_model_ids(page).group_by { |id| id.sub(SNAPSHOT_DATE, "") }.filter_map do |model_id, ids|
                snapshots = ids.filter_map { |id| id[SNAPSHOT_DATE, 1]&.then { |date| Date.parse(date) } }
                dates = [released[model_id], *snapshots].compact
                model_id if dates.any? && [*dates, mentioned[model_id]].compact.min >= cutoff
              end
            end

            def processing_model_ids(page)
              rows = page[SUPPORT_TABLE, 1].to_s.lines.filter_map do |line|
                line.split("|")[1..-2].map(&:strip) if line.start_with?("|")
              end
              header = rows.first.to_a
              processing = header.index { |cell| cell.include?("Processing regions") }
              models = header.index { |cell| cell.include?("Supported models") }
              raise Error, "OpenAI data residency model table not found" unless processing && models

              rows.drop(1).reject { |cells| cells[processing].to_s.match?(/\A(?:None|-*)\z/) }
                  .flat_map { |cells| cells[models].to_s.scan(/`([^`]+)`/).flatten }
            end

            def changelog_dates(changelog)
              year = nil
              day = nil
              changelog.each_line.with_object([{}, {}]) do |line, (released, mentioned)|
                year = line[/\A## \w+, (\d{4})\s*\z/, 1] || year
                heading = line[DAY_HEADING, 1]
                day = Date.parse("#{heading} #{year}") if heading && year
                next unless day

                tagged = line.scan(/Model: ([\w.-]+)/).flatten.map { |id| id.sub(SNAPSHOT_DATE, "") }
                tagged.each { |id| released[id] = [released[id], day].compact.min } if line.match?(/\AFeature\b/)
                (tagged + line.scan(/`([\w.-]+)`/).flatten.map { |id| id.sub(SNAPSHOT_DATE, "") }).each do |id|
                  mentioned[id] = [mentioned[id], day].compact.min
                end
              end
            end

            def data_residency_prices(fields, factor)
              fields.each_with_object({}) do |(field, value), prices|
                next unless field.to_s.match?(PRICE_FIELD) || field.to_s == "transcription_minute"

                prices[data_residency_field(field)] = (value * factor).round(6)
              end
            end

            def data_residency_field(field)
              name = field.to_s
              if name.start_with?("above_context_")
                rest = name.delete_prefix("above_context_")
                "above_context_#{data_residency_field(rest)}"
              elsif (match = name.match(TIER_FIELD))
                "#{match[1]}_data_residency_#{match[2]}"
              else
                "data_residency_#{name}"
              end
            end
          end
        end
      end
    end
  end
end
