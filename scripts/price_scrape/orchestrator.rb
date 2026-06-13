# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "active_support/core_ext/hash/except"
require "date"
require "yaml"

require_relative "../../lib/llm_cost_tracker/pricing/registry"

module LlmCostTracker
  module Pricing::Scrape
    class Orchestrator
      Result = Data.define(:added, :removed, :updated, :service_charges_updated, :unchanged, :written) do
        def changed?
          added.any? || removed.any? || updated.any? || service_charges_updated.any?
        end
      end

      class Error < StandardError; end

      def initialize(writer: LlmCostTracker::Pricing::Sync::RegistryWriter.new, today: Date.today, dry_run: false)
        @writer = writer
        @today = today
        @dry_run = dry_run
      end

      def call(provider:, provider_result:, registry_path:, source_urls: nil)
        provider = normalize_provider(provider)
        registry = read_registry(registry_path)
        current_models = registry.fetch("models", {})
        current_service_charges = registry.fetch("service_charges", {})

        plan = build_plan(provider, provider_result, current_models, current_service_charges)
        source_urls_stale = source_urls && registry.dig("metadata", "source_urls") != source_urls
        return plan unless (plan.changed? || source_urls_stale) && !@dry_run

        metadata = registry.fetch("metadata", {}).merge("updated_at" => @today.iso8601)
        metadata["source_urls"] = source_urls if source_urls
        new_registry = registry.merge(
          "metadata" => metadata,
          "models" => apply_changes(provider, current_models, provider_result, plan.removed)
        )
        service_charges = apply_service_charges(provider, current_service_charges, provider_result)
        new_registry["service_charges"] = service_charges if registry.key?("service_charges") || service_charges.any?
        @writer.call(path: registry_path, registry: new_registry)
        plan.with(written: true)
      end

      private

      def read_registry(path)
        YAML.safe_load_file(path, aliases: false) || {}
      rescue Errno::ENOENT, Psych::Exception, ArgumentError, TypeError => e
        raise Error, "#{e.message} at #{path}"
      end

      def build_plan(provider, provider_result, current_models, current_service_charges)
        deprecated = provider_result.deprecated_models
        active = provider_result.models.except(*deprecated)
        active_keys = active.keys.map { |id| registry_key(provider, id) }
        legacy_active_keys = active.keys.select { |id| bare?(id) && current_models.key?(id) }
        deprecated_keys = deprecated.flat_map do |id|
          bare?(id) ? [registry_key(provider, id), id] : [registry_key(provider, id)]
        end
        removed = Set.new(legacy_active_keys)
        deprecated_keys.each { |id| removed.add(id) if current_models.key?(id) }

        added = active_keys.reject { |id| current_models.key?(id) }
        updated = compute_updates(provider, active, current_models)
        unchanged = active_keys.select { |id| current_models.key?(id) } - updated.keys
        service_charges_updated = compute_service_charge_updates(provider, provider_result, current_service_charges)

        Result.new(
          added: added,
          removed: removed.to_a,
          updated: updated,
          service_charges_updated: service_charges_updated,
          unchanged: unchanged,
          written: false
        )
      end

      def compute_updates(provider, active, current_models)
        active.each_with_object({}) do |(id, scraped_fields), updates|
          key = registry_key(provider, id)
          next unless current_models.key?(key)

          existing = current_models.fetch(key)
          existing_fields = provider_model_fields(existing)
          field_diff = (existing_fields.keys | scraped_fields.keys).sort.each_with_object({}) do |field, diff|
            from = existing_fields[field]
            to = scraped_fields[field]
            diff[field] = { "from" => from, "to" => to } if from != to
          end
          updates[key] = field_diff if field_diff.any?
        end
      end

      def apply_changes(provider, current_models, provider_result, removed_ids)
        active = provider_result.models.except(*provider_result.deprecated_models)
        next_models = current_models.dup
        removed_ids.each { |id| next_models.delete(id) }
        active.each do |id, scraped_fields|
          key = registry_key(provider, id)
          if bare?(id)
            existing = next_models[key] || current_models[id] || {}
            next_models.delete(id)
          else
            existing = next_models[key] || {}
          end
          next_models[key] = preserved_model_fields(existing).merge(scraped_fields)
        end
        next_models
      end

      def compute_service_charge_updates(provider, provider_result, current_service_charges)
        existing = current_service_charges.fetch(provider, {})
        scraped = provider_result.service_charges
        return {} if scraped.empty?

        (existing.keys | scraped.keys).sort.each_with_object({}) do |key, updates|
          from = existing[key]
          to = scraped[key]
          updates[key] = { "from" => from, "to" => to } if from != to
        end
      end

      def apply_service_charges(provider, current_service_charges, provider_result)
        next_service_charges = current_service_charges.dup
        scraped = provider_result.service_charges
        return next_service_charges if scraped.empty?

        next_service_charges[provider] = scraped
        next_service_charges
      end

      def provider_model_fields(entry)
        entry.reject { |field, _value| preserved_model_field?(field) }
      end

      def preserved_model_fields(entry)
        entry.select { |field, _value| preserved_model_field?(field) }
      end

      def preserved_model_field?(field)
        field.start_with?("_") && field != LlmCostTracker::Pricing::Registry::CONTEXT_THRESHOLD_KEY
      end

      def registry_key(provider, model_id)
        "#{provider}/#{model_id}"
      end

      def bare?(model_id)
        !model_id.to_s.include?("/")
      end

      def normalize_provider(provider)
        normalized = provider.to_s.strip.presence
        raise Error, "provider is required" unless normalized

        normalized
      end
    end
  end
end
