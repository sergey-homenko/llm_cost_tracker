# frozen_string_literal: true

require "active_support/core_ext/module/delegation"
require "psych"

require_relative "dimension"

module LlmCostTracker
  module Usage
    module Catalog
      DEFINITIONS_PATH = File.expand_path("dimensions.yml", __dir__)

      DEFAULT_RATE_BASIS_BY_UNIT = {
        "token" => "per_million_tokens",
        "character" => "per_million_characters",
        "request" => "per_request",
        "session" => "per_session",
        "hour" => "per_hour",
        "minute" => "per_minute"
      }.freeze

      class << self
        delegate :[], :fetch, to: :index

        def all
          @all ||= load_definitions.freeze
        end

        def token_priced
          @token_priced ||= all.select { |dimension| dimension.token_key && dimension.parent.nil? }.freeze
        end

        def find_by(kind:, direction:, modality:, cache_state:, unit:)
          by_attributes[[kind, direction, modality, cache_state, unit]]
        end

        def token_priced_for(kind:, direction:, cache_state:)
          dimension = all.find do |candidate|
            candidate.token? && candidate.kind == kind && candidate.direction == direction &&
              candidate.cache_state == cache_state
          end
          dimension&.parent ? fetch(dimension.parent) : dimension
        end

        def costs_by_component(rows)
          rows.each_with_object({}) do |(kind, direction, cache_state, cost), totals|
            component = token_priced_for(kind: kind, direction: direction, cache_state: cache_state)
            totals[component.key] = totals.fetch(component.key, 0) + cost if component && cost
          end
        end

        private

        def index
          @index ||= all.to_h { |dimension| [dimension.key, dimension] }.freeze
        end

        def by_attributes
          @by_attributes ||= all.to_h do |dimension|
            key = [dimension.kind, dimension.direction, dimension.modality, dimension.cache_state, dimension.unit]
            [key, dimension]
          end.freeze
        end

        def load_definitions
          Psych.safe_load_file(DEFINITIONS_PATH, permitted_classes: [], symbolize_names: true)
               .map { |attributes| build(attributes) }
        end

        def build(attributes)
          rate_basis = attributes[:rate_basis] || DEFAULT_RATE_BASIS_BY_UNIT.fetch(attributes.fetch(:unit))
          Dimension.new(parent: nil, **attributes, rate_basis: rate_basis)
        end
      end
    end
  end
end
