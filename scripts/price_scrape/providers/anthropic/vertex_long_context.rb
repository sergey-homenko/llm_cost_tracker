# frozen_string_literal: true

require_relative "../base"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Anthropic < Base
        class VertexLongContext
          ROWS = {
            "Input" => "input", "Output" => "output", "5m Cache Write" => "cache_write_input",
            "1h Cache Write" => "cache_write_extended_input", "Cache Hit" => "cache_read_input"
          }.freeze
          COLUMNS = [/(?:=<|<=|≤)\s*200K input tokens/, />\s*200K input tokens/].freeze
          THRESHOLD = 200_000

          def initialize(vertex, model_ids)
            @vertex = vertex
            @model_ids = model_ids
          end

          def call(models)
            long_context_rows.each_with_object(models.dup) do |(name, rows), priced|
              next if rows.none? { |_field, (short, long)| long && long != short }

              model_id = @model_ids.call(name.sub(/\A(?!Claude )/, "Claude "))
              base = models[model_id]
              next unless base && !base.key?(Pricing::Registry::CONTEXT_THRESHOLD_KEY)

              priced[model_id] = base.merge(above_context_prices(name, rows, base))
            end
          end

          private

          def above_context_prices(name, rows, base)
            unless rows.size == ROWS.size && rows.all? { |field, (short, long)| long && short == base[field] }
              raise Error, "Vertex AI long-context prices for #{name} do not extend Anthropic's: #{rows}"
            end

            rows.to_h { |field, (_short, long)| ["above_context_#{field}", long] }
                .merge(Pricing::Registry::CONTEXT_THRESHOLD_KEY => THRESHOLD)
          end

          def long_context_rows
            table = global_table
            columns = long_context_columns(table)
            model_rows(table).each_with_object({}) do |(model, cells), rows|
              field = ROWS[cells[1]] or next
              (rows[model] ||= {})[field] = cells.values_at(*columns).map { |cell| cell[/\$([\d.]+)/, 1]&.to_f }
            end
          end

          def model_rows(table)
            model = nil
            table.css("tr").filter_map do |tr|
              cells = tr.css("td").map { |td| td.text.gsub(/\s+/, " ").strip }
              next if cells.empty?

              model = cells[0] unless cells[0].empty?
              [model, cells]
            end
          end

          def long_context_columns(table)
            headers = table.at_css("tr").css("th").map { |th| th.text.strip }
            COLUMNS.map do |label|
              headers.find_index { |header| header.match?(label) } or
                raise Error, "Vertex AI Claude long-context columns not found in #{headers.inspect}"
            end
          end

          def global_table
            tab = @vertex.css("#anthropics-claude-models [role=tab]").find { |button| button.text.strip == "Global" }
            table = tab && @vertex.at_css("#anthropics-claude-models [aria-labelledby='#{tab['id']}'] table")
            raise Error, "Vertex AI Claude Global pricing table not found" unless table

            table
          end
        end
      end
    end
  end
end
