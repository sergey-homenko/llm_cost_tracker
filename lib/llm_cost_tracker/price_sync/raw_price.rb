# frozen_string_literal: true

module LlmCostTracker
  module PriceSync
    RawPrice = Data.define(
      :model,
      :provider,
      :input,
      :output,
      :cache_read_input,
      :cache_write_input,
      :source,
      :source_version,
      :fetched_at
    )

    class RawPrice
      PRICE_FIELDS = %w[input output cache_read_input cache_write_input].freeze

      def to_registry_entry(today:)
        {
          "input" => input,
          "output" => output,
          "cache_read_input" => cache_read_input,
          "cache_write_input" => cache_write_input,
          "_source" => source.to_s,
          "_source_version" => source_version,
          "_fetched_at" => fetched_at || today.iso8601
        }.compact
      end
    end
  end
end
