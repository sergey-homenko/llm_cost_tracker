# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    class PricingOverview
      SOURCES = %i[overrides file bundled].freeze
      RATE_COLUMNS = %w[input output cache_read_input cache_write_input batch_input batch_output].freeze
      Row = Data.define(:provider, :model, :rates)

      class << self
        def call
          new.call
        end
      end

      def call
        sources = SOURCES.each_with_object({}) do |source, acc|
          built = build_source(source)
          acc[source] = built if built
        end
        {
          sources: sources,
          effective_source: sources.keys.first || :bundled
        }
      end

      private

      def build_source(source)
        case source
        when :overrides then build_overrides
        when :file then build_file
        when :bundled then build_bundled
        end
      end

      def build_overrides
        prices = LlmCostTracker.configuration.pricing_overrides
        return nil if prices.nil? || prices.empty?

        {
          label: "Overrides",
          subtitle: "config.pricing_overrides",
          updated_at: nil,
          currency: nil,
          rows: build_rows(prices)
        }
      end

      def build_file
        path = LlmCostTracker.configuration.prices_file
        return nil unless path && File.exist?(path)

        prices = Pricing::Registry.file_prices(path)
        return nil if prices.empty?

        meta = Pricing::Registry.file_metadata(path)
        {
          label: "Custom file",
          subtitle: path.to_s,
          updated_at: meta["updated_at"] || Pricing::Lookup.prices_file_mtime_iso,
          currency: meta["currency"] || Billing::DEFAULT_CURRENCY,
          rows: build_rows(prices)
        }
      end

      def build_bundled
        prices = Pricing::Registry.builtin_prices
        meta = Pricing::Registry.metadata
        {
          label: "Bundled",
          subtitle: "ships with the gem",
          updated_at: meta["updated_at"],
          currency: meta["currency"] || Billing::DEFAULT_CURRENCY,
          rows: build_rows(prices)
        }
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
