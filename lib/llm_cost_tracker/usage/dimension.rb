# frozen_string_literal: true

require "psych"

module LlmCostTracker
  module Usage
    DEFAULT_RATE_BASIS_BY_UNIT = {
      "token" => "per_million_tokens",
      "character" => "per_million_characters",
      "request" => "per_request",
      "session" => "per_session",
      "hour" => "per_hour",
      "minute" => "per_minute",
      "image" => "per_image"
    }.freeze

    Dimension = Data.define(
      :key, :kind, :direction, :modality, :cache_state, :unit, :rate_basis
    ) do
      def token?
        unit == "token"
      end

      def token_key
        :"#{key}_tokens" if token?
      end

      def cost_key
        :"#{key}_cost" if token?
      end
    end

    class Dimension
      DEFINITIONS_PATH = File.expand_path("dimensions.yml", __dir__)

      def self.load
        Psych.safe_load_file(DEFINITIONS_PATH, permitted_classes: [], symbolize_names: true)
             .map { |attributes| build(attributes) }
             .freeze
      end

      def self.build(attributes)
        rate_basis = attributes[:rate_basis] || DEFAULT_RATE_BASIS_BY_UNIT.fetch(attributes.fetch(:unit))
        new(**attributes, rate_basis: rate_basis)
      end

      def self.parse_key(key)
        name = key.to_s
        ALL.each do |dimension|
          return [dimension, nil] if dimension.key == name

          suffix = "_#{dimension.key}"
          next unless name.end_with?(suffix)

          prefix = name.delete_suffix(suffix)
          return [dimension, prefix] unless prefix.empty?
        end
        nil
      end

      def self.token_priced_for(kind:, direction:, cache_state:)
        TOKEN_PRICED.find do |dimension|
          dimension.kind == kind && dimension.direction == direction && dimension.cache_state == cache_state
        end
      end

      ALL = load
      BY_KEY = ALL.to_h { |dimension| [dimension.key, dimension] }.freeze
      TOKEN_PRICED = ALL.select(&:token_key).freeze
    end
  end
end
