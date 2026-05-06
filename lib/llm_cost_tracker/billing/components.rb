# frozen_string_literal: true

require "psych"

require_relative "../errors"

module LlmCostTracker
  module Billing
    module Components
      Component = Data.define(
        :key,
        :kind,
        :direction,
        :modality,
        :cache_state,
        :unit,
        :category,
        :token_key,
        :cost_key
      )

      REQUIRED_FIELDS = %i[key kind direction modality cache_state unit category].freeze
      DEFINITIONS_PATH = File.expand_path("components.yml", __dir__)

      def self.load_registry
        Psych.safe_load_file(DEFINITIONS_PATH, permitted_classes: [], symbolize_names: true)
             .map { |attributes| build(attributes) }
             .freeze
      end

      def self.build(attributes)
        missing = REQUIRED_FIELDS - attributes.keys
        raise Error, "components.yml entry missing #{missing.join(', ')}: #{attributes.inspect}" if missing.any?

        Component.new(
          key: attributes.fetch(:key).to_sym,
          kind: attributes.fetch(:kind).to_sym,
          direction: attributes.fetch(:direction).to_sym,
          modality: attributes.fetch(:modality).to_sym,
          cache_state: attributes.fetch(:cache_state).to_sym,
          unit: attributes.fetch(:unit).to_sym,
          category: attributes.fetch(:category).to_sym,
          token_key: attributes[:token_key]&.to_sym,
          cost_key: attributes[:cost_key]&.to_sym
        )
      end

      REGISTRY = load_registry
      BY_KEY = REGISTRY.to_h { |component| [component.key, component] }.freeze
      TOKEN_PRICED = REGISTRY.select { |component| component.token_key && component.cost_key }.freeze
    end
  end
end
