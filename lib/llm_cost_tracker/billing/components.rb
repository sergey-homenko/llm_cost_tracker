# frozen_string_literal: true

require "psych"

require_relative "../errors"

module LlmCostTracker
  module Billing
    RATE_BASIS_QUANTITIES = {
      per_million_tokens: 1_000_000,
      per_million_characters: 1_000_000,
      per_request: 1,
      per_1k_requests: 1_000,
      per_session: 1,
      per_hour: 1,
      per_gb_day: 1,
      per_image: 1
    }.freeze

    RATE_BASES = RATE_BASIS_QUANTITIES.keys.freeze

    DEFAULT_RATE_BASIS_BY_UNIT = {
      token: :per_million_tokens,
      character: :per_million_characters,
      request: :per_request,
      session: :per_session,
      hour: :per_hour,
      image: :per_image
    }.freeze

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
        :cost_key,
        :rate_basis
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

        unit = attributes.fetch(:unit).to_sym
        rate_basis = attributes[:rate_basis]&.to_sym || Billing::DEFAULT_RATE_BASIS_BY_UNIT[unit]
        if rate_basis.nil?
          raise Error, "components.yml entry needs rate_basis for unit #{unit.inspect}: #{attributes.inspect}"
        end
        unless Billing::RATE_BASES.include?(rate_basis)
          raise Error, "components.yml entry has unknown rate_basis #{rate_basis.inspect}: #{attributes.inspect}"
        end

        Component.new(
          key: attributes.fetch(:key).to_sym,
          kind: attributes.fetch(:kind).to_sym,
          direction: attributes.fetch(:direction).to_sym,
          modality: attributes.fetch(:modality).to_sym,
          cache_state: attributes.fetch(:cache_state).to_sym,
          unit: unit,
          category: attributes.fetch(:category).to_sym,
          token_key: attributes[:token_key]&.to_sym,
          cost_key: attributes[:cost_key]&.to_sym,
          rate_basis: rate_basis
        )
      end

      REGISTRY = load_registry
      BY_KEY = REGISTRY.to_h { |component| [component.key, component] }.freeze
      TOKEN_PRICED = REGISTRY.select { |component| component.token_key && component.cost_key }.freeze
    end
  end
end
