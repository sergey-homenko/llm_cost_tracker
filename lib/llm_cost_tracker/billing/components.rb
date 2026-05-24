# frozen_string_literal: true

require "psych"

require_relative "../errors"

module LlmCostTracker
  module Billing
    DEFAULT_CURRENCY = "USD"

    RATE_BASIS_QUANTITIES = {
      "per_million_tokens" => 1_000_000,
      "per_million_characters" => 1_000_000,
      "per_request" => 1,
      "per_1k_requests" => 1_000,
      "per_session" => 1,
      "per_hour" => 1
    }.freeze

    DEFAULT_RATE_BASIS_BY_UNIT = {
      "token" => "per_million_tokens",
      "character" => "per_million_characters",
      "request" => "per_request",
      "session" => "per_session",
      "hour" => "per_hour"
    }.freeze

    module Components
      Component = Data.define(
        :key, :kind, :direction, :modality, :cache_state, :unit,
        :token_key, :cost_key, :rate_basis
      )

      REQUIRED_FIELDS = %i[key kind direction modality cache_state unit].freeze
      DEFINITIONS_PATH = File.expand_path("components.yml", __dir__)

      def self.load_registry
        Psych.safe_load_file(DEFINITIONS_PATH, permitted_classes: [], symbolize_names: true)
             .map { |attributes| build(attributes) }
             .freeze
      end

      def self.build(attributes)
        unit = attributes.fetch(:unit)
        key = attributes.fetch(:key)
        Component.new(
          **attributes.slice(*REQUIRED_FIELDS),
          rate_basis: attributes[:rate_basis] || Billing::DEFAULT_RATE_BASIS_BY_UNIT.fetch(unit),
          token_key: unit == "token" ? :"#{key}_tokens" : nil,
          cost_key: unit == "token" ? :"#{key}_cost" : nil
        )
      end

      REGISTRY = load_registry
      BY_KEY = REGISTRY.to_h { |component| [component.key, component] }.freeze
      TOKEN_PRICED = REGISTRY.select(&:token_key).freeze
    end
  end
end
