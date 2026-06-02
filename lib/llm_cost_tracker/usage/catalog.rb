# frozen_string_literal: true

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
        "minute" => "per_minute",
        "image" => "per_image"
      }.freeze

      class << self
        def all
          @all ||= load_definitions.freeze
        end

        def [](key)
          index[key]
        end

        def fetch(key)
          index.fetch(key)
        end

        def token_priced
          @token_priced ||= all.select(&:token_key).freeze
        end

        def token_priced_for(kind:, direction:, cache_state:)
          token_priced.find do |dimension|
            dimension.kind == kind && dimension.direction == direction && dimension.cache_state == cache_state
          end
        end

        private

        def index
          @index ||= all.to_h { |dimension| [dimension.key, dimension] }.freeze
        end

        def load_definitions
          Psych.safe_load_file(DEFINITIONS_PATH, permitted_classes: [], symbolize_names: true)
               .map { |attributes| build(attributes) }
        end

        def build(attributes)
          rate_basis = attributes[:rate_basis] || DEFAULT_RATE_BASIS_BY_UNIT.fetch(attributes.fetch(:unit))
          Dimension.new(**attributes, rate_basis: rate_basis)
        end
      end
    end
  end
end
