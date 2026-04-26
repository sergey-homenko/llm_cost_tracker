# frozen_string_literal: true

require "date"
require "json"

module LlmCostTracker
  module PriceScrape
    class Orchestrator
      Result = Data.define(:added, :removed, :updated, :unchanged, :written) do
        def changed?
          added.any? || removed.any? || updated.any?
        end
      end

      class Error < StandardError; end

      def initialize(writer: LlmCostTracker::PriceSync::RegistryWriter.new, today: Date.today, dry_run: false)
        @writer = writer
        @today = today
        @dry_run = dry_run
      end

      def call(provider_result:, registry_path:)
        registry = read_registry(registry_path)
        current_models = registry.fetch("models", {})

        plan = build_plan(provider_result, current_models)
        return plan unless plan.changed? && !@dry_run

        new_registry = registry.merge(
          "metadata" => registry.fetch("metadata", {}).merge("updated_at" => @today.iso8601),
          "models" => apply_changes(current_models, provider_result, plan.removed)
        )
        @writer.call(path: registry_path, registry: new_registry)
        plan.with(written: true)
      end

      private

      def read_registry(path)
        contents = File.read(path)
        registry = JSON.parse(contents)
        raise Error, "registry must be a JSON object at #{path}" unless registry.is_a?(Hash)

        registry
      end

      def build_plan(provider_result, current_models)
        deprecated = provider_result.deprecated_models
        active = provider_result.models.except(*deprecated)

        added = active.keys - current_models.keys
        removed = deprecated & current_models.keys
        updated = compute_updates(active, current_models)
        unchanged = (active.keys & current_models.keys) - updated.keys

        Result.new(added: added, removed: removed, updated: updated, unchanged: unchanged, written: false)
      end

      def compute_updates(active, current_models)
        active.each_with_object({}) do |(id, scraped_fields), updates|
          next unless current_models.key?(id)

          existing = current_models.fetch(id)
          field_diff = scraped_fields.each_with_object({}) do |(field, value), diff|
            diff[field] = { "from" => existing[field], "to" => value } if existing[field] != value
          end
          updates[id] = field_diff if field_diff.any?
        end
      end

      def apply_changes(current_models, provider_result, removed_ids)
        active = provider_result.models.except(*provider_result.deprecated_models)
        next_models = current_models.dup
        removed_ids.each { |id| next_models.delete(id) }
        active.each do |id, scraped_fields|
          next_models[id] = (next_models[id] || {}).merge(scraped_fields)
        end
        next_models
      end
    end
  end
end
