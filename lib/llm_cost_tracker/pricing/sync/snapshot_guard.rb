# frozen_string_literal: true

require "bigdecimal"

require_relative "../../currency"
require_relative "../registry"
require_relative "registry_writer"

module LlmCostTracker
  module Pricing
    module Sync
      module SnapshotGuard
        PRICE_FACTOR = 100
        MAX_REMOVED_MODEL_SHARE = Rational(1, 3)
        BASE_PRICE_KEYS = %w[input output].freeze

        class << self
          def call(current:, remote:, changes:)
            current_models = current["models"] || {}
            remote_models = remote.fetch("models", {})
            findings = model_findings(changes.except("service_charges"), remote_models)
            findings.concat(service_charge_findings(changes.fetch("service_charges", {})))
            findings << removed_models_finding(current_models, remote_models)
            findings << currency_finding(current, remote) unless current_models.empty?
            findings.compact
          end

          private

          def model_findings(model_changes, remote_models)
            model_changes.flat_map do |model, fields|
              next [] unless remote_models.key?(model)

              fields.filter_map do |field, values|
                next if field == Registry::CONTEXT_THRESHOLD_KEY

                price_finding("#{model} #{field}", field, values)
              end
            end
          end

          def service_charge_findings(charge_changes)
            charge_changes.flat_map do |provider, components|
              components.filter_map do |component, values|
                price_finding("#{provider}.#{component}", component, values)
              end
            end
          end

          def price_finding(label, field, values)
            reason = price_change_reason(field, amount(values["from"]), amount(values["to"]))
            "#{label}: #{display(values['from'])} -> #{display(values['to'])} (#{reason})" if reason
          end

          def price_change_reason(field, from, to)
            if to.nil?
              "removed" if from&.positive? && BASE_PRICE_KEYS.include?(field)
            elsif from.nil?
              nil
            elsif from.zero?
              "was zero" if to.positive?
            elsif to.zero?
              "set to zero"
            else
              ratio_reason(to / from)
            end
          end

          def ratio_reason(ratio)
            if ratio >= PRICE_FACTOR
              "up #{PRICE_FACTOR}x or more"
            elsif ratio * PRICE_FACTOR <= 1
              "down #{PRICE_FACTOR}x or more"
            end
          end

          def removed_models_finding(current_models, remote_models)
            refreshed = current_models.keys.reject { |model| manual?(current_models[model]) }
            removed = refreshed.count { |model| !remote_models.key?(model.to_s) }
            return nil unless removed > refreshed.size * MAX_REMOVED_MODEL_SHARE

            "#{removed} of #{refreshed.size} models removed"
          end

          def currency_finding(current, remote)
            from = currency(current)
            to = currency(remote)
            "currency: #{from} -> #{to}" unless from == to
          end

          def manual?(attrs)
            attrs.is_a?(Hash) && attrs["_source"].to_s == RegistryWriter::MANUAL_SOURCE
          end

          def currency(registry)
            metadata = registry["metadata"]
            currency = metadata["currency"] if metadata.is_a?(Hash)
            (currency || LlmCostTracker::DEFAULT_CURRENCY).to_s.upcase
          end

          def amount(value)
            return nil if value.nil?

            BigDecimal(value.to_s)
          rescue ArgumentError, TypeError
            nil
          end

          def display(value)
            (value.is_a?(BigDecimal) ? value.to_f : value).inspect
          end
        end
      end
    end
  end
end
