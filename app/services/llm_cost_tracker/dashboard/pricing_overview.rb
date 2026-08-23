# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    class PricingOverview
      SOURCES = %i[overrides file bundled].freeze
      RATE_COLUMNS = %w[input output cache_read_input cache_write_input batch_input batch_output].freeze
      Row = Data.define(:provider, :model, :rates)

      SOURCE_NAME = { overrides: "pricing_overrides", file: "prices_file", bundled: "bundled" }.freeze
      LABEL = { overrides: "Overrides", file: "Custom file", bundled: "Bundled" }.freeze
      private_constant :SOURCE_NAME, :LABEL

      class << self
        def call
          new.call
        end
      end

      def call
        sources = SOURCES.each_with_object({}) do |key, acc|
          source = sources_by_name.fetch(SOURCE_NAME.fetch(key))
          acc[key] = present(key, source) unless source.prices.empty?
        end
        {
          sources: sources,
          effective_source: sources.keys.first || :bundled
        }
      end

      private

      def sources_by_name
        @sources_by_name ||= Pricing::Registry.sources.to_h { |source| [source.name, source] }
      end

      def present(key, source)
        {
          label: LABEL.fetch(key),
          subtitle: subtitle_for(key),
          updated_at: updated_at_for(key),
          currency: source.currency,
          rows: build_rows(source.prices)
        }
      end

      def subtitle_for(key)
        case key
        when :overrides then "config.pricing.overrides"
        when :file then LlmCostTracker.configuration.pricing.file.to_s
        when :bundled then "ships with the gem"
        end
      end

      def updated_at_for(key)
        case key
        when :file
          path = LlmCostTracker.configuration.pricing.file
          Pricing::Registry.file_metadata(path)["updated_at"] || Pricing::Registry.prices_file_mtime_iso
        when :bundled
          Pricing::Registry.metadata["updated_at"]
        end
      end

      def build_rows(prices)
        rows = prices.map do |key, rates|
          provider, model = split_key(key.to_s)
          Row.new(provider: provider, model: model, rates: rates)
        end
        rows.sort_by { |row| [row.provider || "~", row.model] }
      end

      def split_key(key)
        provider, model = key.split("/", 2)
        return [provider, model] if model

        [nil, provider]
      end
    end
  end
end
