# frozen_string_literal: true

require_relative "../../currency"

module LlmCostTracker
  module Pricing
    module Sync
      module SnapshotGuard
        PRICE_FACTOR = 100
        BASE_PRICE_KEYS = %w[input output].freeze

        class << self
          def call(current:, remote:, changes:)
            findings = changes.except("service_charges").flat_map do |model, fields|
              next [] unless remote["models"].key?(model)

              fields.map { |field, values| finding("#{model} #{field}", field, values) }
            end
            changes.fetch("service_charges", {}).each do |provider, components|
              components.each { |component, values| findings << finding("#{provider}.#{component}", component, values) }
            end
            (findings << currency_finding(current, remote)).compact
          end

          private

          def finding(label, field, values)
            from, to = values.values_at("from", "to").map { |value| value&.to_f }
            "#{label}: #{from.inspect} -> #{to.inspect}" if suspicious?(field, from, to)
          end

          def suspicious?(field, from, to)
            return BASE_PRICE_KEYS.include?(field) && from.positive? if to.nil?
            return false if from.nil?
            return true if from.zero? || to.zero?

            [to / from, from / to].max >= PRICE_FACTOR
          end

          def currency_finding(current, remote)
            return if current.empty?

            from, to = [current, remote].map { |registry| registry.dig("metadata", "currency") || DEFAULT_CURRENCY }
            "currency: #{from} -> #{to}" unless from.upcase == to.upcase
          end
        end
      end
    end
  end
end
