# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Gemini
      class Grounding
        CANDIDATE_FIELDS = {
          "grounding_request" => "response.candidates.groundingMetadata.webSearchQueries",
          "maps_grounding_request" => "response.candidates.groundingMetadata.groundingChunks.maps"
        }.freeze
        TOOL_KINDS = {
          "google_search" => "grounding_request",
          "google_maps" => "maps_grounding_request"
        }.freeze
        TOOL_COUNT_FIELD = "response.usage.grounding_tool_count"

        class << self
          def from_response(response)
            usage = response["usage"]
            return from_candidates(response["candidates"]) unless usage.is_a?(Hash)

            from_tool_counts(usage["grounding_tool_count"])
          end

          def from_candidates(candidates)
            counts = Array(candidates).each_with_object(Hash.new(0)) do |candidate, totals|
              metadata = candidate["groundingMetadata"]
              next unless metadata.is_a?(Hash)

              kind, count = metadata_count(metadata)
              totals[kind] += count
            end
            new(counts)
          end

          private

          def from_tool_counts(entries)
            counts = Array(entries).each_with_object(Hash.new(0)) do |entry, totals|
              kind = TOOL_KINDS[entry["type"]]
              totals[kind] += entry["count"].to_i if kind
            end
            new(counts, provider_field: TOOL_COUNT_FIELD)
          end

          def metadata_count(metadata)
            queries = unique_count(metadata["webSearchQueries"])
            if Array(metadata["groundingChunks"]).any? { |chunk| chunk.is_a?(Hash) && chunk.key?("maps") }
              ["maps_grounding_request", [queries, 1].max]
            else
              ["grounding_request", queries + unique_count(metadata["imageSearchQueries"])]
            end
          end

          def unique_count(queries)
            Array(queries).map { |query| query.to_s.strip }.reject(&:empty?).uniq.size
          end
        end

        def initialize(counts, provider_field: nil)
          @counts = counts
          @provider_field = provider_field
        end

        def any?
          @counts.values.any?(&:positive?)
        end

        def line_items(model:)
          per_query = ModelFamilies.per_query_grounding?(model)
          @counts.filter_map do |kind, count|
            next unless count.positive?

            Charges::LineItem.build(
              dimension_key: kind,
              quantity: per_query ? count : 1,
              cost_status: Charges::CostStatus::UNKNOWN,
              pricing_basis: "provider_usage",
              provider_field: @provider_field || CANDIDATE_FIELDS.fetch(kind),
              details: { web_search_queries: count }
            )
          end
        end
      end
    end
  end
end
