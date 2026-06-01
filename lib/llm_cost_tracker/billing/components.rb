# frozen_string_literal: true

require "psych"

module LlmCostTracker
  module Billing
    DEFAULT_CURRENCY = "USD"

    RATE_BASIS_QUANTITIES = {
      "per_million_tokens" => 1_000_000,
      "per_million_characters" => 1_000_000,
      "per_request" => 1,
      "per_1k_requests" => 1_000,
      "per_session" => 1,
      "per_hour" => 1,
      "per_minute" => 1,
      "per_image" => 1
    }.freeze

    DEFAULT_RATE_BASIS_BY_UNIT = {
      "token" => "per_million_tokens",
      "character" => "per_million_characters",
      "request" => "per_request",
      "session" => "per_session",
      "hour" => "per_hour",
      "minute" => "per_minute",
      "image" => "per_image"
    }.freeze

    module Components
      Component = Data.define(
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

      DEFINITIONS_PATH = File.expand_path("components.yml", __dir__)

      def self.load_registry
        Psych.safe_load_file(DEFINITIONS_PATH, permitted_classes: [], symbolize_names: true)
             .map { |attributes| build(attributes) }
             .freeze
      end

      def self.build(attributes)
        rate_basis = attributes[:rate_basis] || Billing::DEFAULT_RATE_BASIS_BY_UNIT.fetch(attributes.fetch(:unit))
        Component.new(**attributes, rate_basis: rate_basis)
      end

      def self.parse_key(key)
        name = key.to_s
        REGISTRY.each do |component|
          return [component, nil] if component.key == name

          suffix = "_#{component.key}"
          next unless name.end_with?(suffix)

          prefix = name.delete_suffix(suffix)
          return [component, prefix] unless prefix.empty?
        end
        nil
      end

      def self.token_priced_for(kind:, direction:, cache_state:)
        TOKEN_PRICED.find do |component|
          component.kind == kind && component.direction == direction && component.cache_state == cache_state
        end
      end

      REGISTRY = load_registry
      BY_KEY = REGISTRY.to_h { |component| [component.key, component] }.freeze
      TOKEN_PRICED = REGISTRY.select(&:token_key).freeze
    end
  end
end
