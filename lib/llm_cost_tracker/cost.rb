# frozen_string_literal: true

require "active_support/core_ext/hash/keys"

module LlmCostTracker
  Cost = Data.define(
    :input_cost,
    :cache_read_input_cost,
    :cache_write_input_cost,
    :cache_write_1h_input_cost,
    :output_cost,
    :total_cost,
    :currency
  ) do
    def self.from_hash(attributes)
      attributes = attributes.to_h.symbolize_keys
      new(
        input_cost: attributes[:input_cost],
        cache_read_input_cost: attributes[:cache_read_input_cost],
        cache_write_input_cost: attributes[:cache_write_input_cost],
        cache_write_1h_input_cost: attributes[:cache_write_1h_input_cost],
        output_cost: attributes[:output_cost],
        total_cost: attributes[:total_cost],
        currency: attributes[:currency]
      )
    end

    def stored_attributes
      to_h.slice(*STORED_KEYS)
    end

    def to_h
      super.compact
    end
  end

  Cost::BASE_STORED_KEYS = %i[
    input_cost
    output_cost
    total_cost
  ].freeze

  Cost::OPTIONAL_STORED_KEYS = %i[
    cache_read_input_cost
    cache_write_input_cost
    cache_write_1h_input_cost
  ].freeze

  Cost::STORED_KEYS = (Cost::BASE_STORED_KEYS + Cost::OPTIONAL_STORED_KEYS).freeze

  Cost::BASE_DASHBOARD_SUM_KEYS = %i[
    input_cost
    output_cost
  ].freeze

  Cost::OPTIONAL_DASHBOARD_SUM_KEYS = %i[
    cache_read_input_cost
    cache_write_input_cost
    cache_write_1h_input_cost
  ].freeze

  Cost::DASHBOARD_SUM_KEYS = (Cost::BASE_DASHBOARD_SUM_KEYS + Cost::OPTIONAL_DASHBOARD_SUM_KEYS).freeze
end
