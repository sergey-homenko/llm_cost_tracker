# frozen_string_literal: true

require "date"

require_relative "../base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Gemini < Base
        class NonGlobalPrices
          NON_GLOBAL_FROM = /
            For\snon-global\sendpoints,\spricing\swill\sgo\sinto\seffect\sfor\sthe\sGenerally\savailable\sGemini\s3\sand
            \slater\sfamilies\sof\sall\sGoogle\smodels\sstarting\son\s(\w+\s\d{1,2},\s\d{4})\.\sBefore\s\1,\sGlobal
            \sendpoint\spricing\sapplies\sto\sNon-global\sendpoints\.
          /x
          VERTEX_TIER_PREFIXES = { "with Priority" => %w[priority_], "with Flex/Batch" => %w[flex_ batch_] }.freeze
          VERTEX_ROWS = {
            "Input (text, image, video, audio)" => %w[input image_input audio_input],
            "Text output (response and reasoning)" => %w[output]
          }.freeze
          DATED_FIELD = /_from_(?=\d{4}-\d{2}-\d{2}\z)/
          TIERED_FIELD = /\A(above_context_)?(batch_|flex_|priority_)?(.+)\z/

          def initialize(vertex)
            @vertex = vertex
          end

          def call(models)
            from = non_global_from
            factor, names = uplift
            ids = names.uniq.to_h { |name| [name, vertex_model_id(name)] }
            unless ids.values.intersect?(models.keys)
              raise Error, "Vertex AI non-global prices name no Gemini API model"
            end

            models = models.merge(vertex_only_models(ids.values - models.keys))
            [with_non_global_prices(models, ids.values, factor, Date.parse(from)), unread_notes(ids, models)]
          end

          private

          def non_global_from
            from = @vertex.text.gsub(/\s+/, " ")[NON_GLOBAL_FROM, 1]
            raise Error, "Vertex AI non-global pricing note not found" unless from

            from
          end

          def uplift
            pairs = non_global_pairs
            ratios = pairs.flat_map do |_model, global, prices|
              global.zip(prices).filter_map { |base, price| (price / base).round(6) if base&.positive? && price }
            end.uniq
            raise Error, "Vertex AI non-global prices are not one uplift: #{ratios.inspect}" unless ratios.one?

            [ratios.first, pairs.map(&:first)]
          end

          def non_global_pairs
            model = global = nil
            region_rows.each_with_object([]) do |cells, pairs|
              global = nil unless cells[0].empty? && cells[1].empty?
              model = cells[0] unless cells[0].empty?
              prices = vertex_prices(cells)
              if cells[2].match?(/\Aglobal/i)
                global = prices
              elsif global
                pairs << [model, global, prices]
              end
            end
          end

          def region_rows
            @vertex.css("tr").map { |tr| row_cells(tr) }.select { |cells| cells[2].to_s.match?(/\A(?:Non-)?global/i) }
          end

          def vertex_only_models(model_ids)
            rows = global_rows
            model_ids.uniq.each_with_object({}) do |model_id, priced|
              prices = vertex_only_prices(rows.select { |name, *| vertex_model_id(name) == model_id })
              priced[model_id] = prices if prices
            end
          end

          def global_rows
            @vertex.css("table").flat_map do |table|
              header = joined_text(table.at_css("tr"))
              next [] unless header.include?("> 200K input tokens")

              prefixes = VERTEX_TIER_PREFIXES.find { |label, _| header.include?(label) }&.last || [""]
              table_global_rows(table, prefixes)
            end
          end

          def table_global_rows(table, prefixes)
            model = type = ""
            table.css("tr").filter_map do |tr|
              cells = row_cells(tr)
              model = cells[0] unless cells[0].to_s.empty?
              type = cells[1] unless cells[1].to_s.empty?
              [model, type, prefixes, *vertex_prices(cells)] if cells[2].to_s.match?(/\Aglobal/i)
            end
          end

          def vertex_only_prices(rows)
            return unless rows.all? { |_, type, _, base, long| VERTEX_ROWS.key?(type) && base && long == base }

            entries = rows.flat_map do |_model, type, prefixes, base, _long, cached|
              price_entries(type, prefixes, base, cached)
            end
            complete_prices(entries)
          end

          def price_entries(type, prefixes, base, cached)
            fields = VERTEX_ROWS[type].map { |field| [field, base] }
            fields << ["cache_read_input", cached] if cached
            prefixes.product(fields).map { |prefix, (field, price)| ["#{prefix}#{field}", price] }
          end

          def complete_prices(entries)
            unique = entries.uniq
            prices = unique.to_h
            prices if prices.size == unique.size && prices.key?("input") && prices.key?("output")
          end

          def with_non_global_prices(models, model_ids, factor, from)
            priced = (model_ids & models.keys).to_h do |model_id|
              [model_id, models[model_id].merge(non_global_prices(models[model_id], factor, from))]
            end
            models.merge(priced)
          end

          def non_global_prices(fields, factor, from)
            fields.each_with_object({}) do |(field, value), prices|
              base, date = field.split(DATED_FIELD)
              context, tier, dimension = base.match(TIERED_FIELD).captures
              next unless Pricing::Registry::PRICE_KEYS.include?(dimension)

              key = "#{context}#{tier}data_residency_#{dimension}_from_#{date || from.iso8601}"
              prices[key] = (value * factor).round(6)
            end
          end

          def unread_notes(ids, models)
            ids.reject { |_name, id| models.key?(id) }.keys.map do |name|
              "- `gemini`: Vertex AI prices #{name} in rows the scraper cannot read, " \
                "and the Gemini API page does not price it"
            end
          end

          def row_cells(row) = row.css("td").map { |td| joined_text(td) }

          def vertex_prices(cells) = cells.drop(3).map { |cell| cell[/\$([\d.]+)/, 1]&.to_f }

          def joined_text(node) = node.xpath(".//text()").map(&:text).join(" ").gsub(/\s+/, " ").strip

          def vertex_model_id(name)
            name.split(/\s*(?:[*(]|\b(?:through|starting)\b)/i).first.to_s.strip.downcase.tr(" ", "-")
          end
        end
      end
    end
  end
end
