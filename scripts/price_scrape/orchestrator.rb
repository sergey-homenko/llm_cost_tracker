# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "active_support/core_ext/hash/except"
require "date"
require "yaml"

require_relative "../../lib/llm_cost_tracker/pricing/registry"

module LlmCostTracker
  module Pricing::Scrape
    class Orchestrator
      Result = Data.define(
        :added, :removed, :updated, :service_charges_updated, :unchanged, :written, :notes, :absent
      ) do
        def initialize(notes: [], absent: {}, **) = super

        def changed?
          added.any? || removed.any? || updated.any? || service_charges_updated.any? || absent.any?
        end
      end

      MIN_GEM_VERSIONS = {
        "_off_peak_windows" => "0.15.0", "ocr_page" => "0.15.0", "openai/gpt-4o-mini-tts" => "0.15.0",
        "text_to_speech_character" => "0.15.0", "_minimum_billed_seconds" => "0.15.0", "cohere" => "0.15.0"
      }.freeze
      PRUNE_AFTER_DAYS = 90

      class Error < StandardError; end

      def initialize(writer: LlmCostTracker::Pricing::Sync::RegistryWriter.new, today: Date.today, dry_run: false)
        @writer = writer
        @today = today
        @dry_run = dry_run
      end

      def call(provider:, provider_result:, registry_path:, source_urls: nil)
        provider = normalize_provider(provider)
        registry = read_registry(registry_path)
        held = held_models(provider, provider_result.models, registry.dig("metadata", "min_gem_version"))
        scraped = provider_result.with(models: provider_result.models.except(*held.keys))
        plan = build_plan(provider, scraped, registry, held)
        return plan if @dry_run || !(plan.changed? || stale_source_urls?(registry, source_urls))

        @writer.call(path: registry_path, registry: updated_registry(provider, scraped, registry, plan, source_urls))
        plan.with(written: true)
      end

      private

      def normalize_provider(provider)
        provider.to_s.strip.presence or raise Error, "provider is required"
      end

      def read_registry(path)
        YAML.safe_load_file(path, aliases: false) || {}
      rescue Errno::ENOENT, Psych::Exception, ArgumentError, TypeError => e
        raise Error, "#{e.message} at #{path}"
      end

      def held_models(provider, models, min_gem_version)
        floor = Gem::Version.new(min_gem_version || "0")
        models.each_with_object({}) do |(id, fields), held|
          required = MIN_GEM_VERSIONS.values_at(provider, registry_key(provider, id), *fields.keys).compact
                                     .max_by { |version| Gem::Version.new(version) }
          held[id] = required if required && Gem::Version.new(required) > floor
        end
      end

      def held_notes(provider, held)
        return [] if held.empty?

        version = held.values.max_by { |required| Gem::Version.new(required) }
        ["- `#{provider}`: #{held.keys.sort.join(', ')} held until metadata.min_gem_version is #{version}"]
      end

      def build_plan(provider, scraped, registry, held)
        current = registry.fetch("models", {})
        plan = model_changes(provider, scraped, current, registry.fetch("service_charges", {}))
               .with(notes: held_notes(provider, held))
        missing = current.keys.select { |key| key.start_with?("#{provider}/") } - listed_keys(plan, provider, held)
        with_absences(plan, provider, missing, registry.dig("metadata", "absent_since") || {})
      end

      def model_changes(provider, scraped, current, current_charges)
        active = scraped.models.except(*scraped.deprecated_models)
        ensure_long_context_pricing_kept!(provider, active, current)
        keys = active.keys.map { |id| registry_key(provider, id) }
        updated = model_updates(provider, active, current)
        Result.new(
          added: keys.reject { |key| current.key?(key) },
          removed: removed_keys(provider, active, scraped.deprecated_models, current),
          updated:,
          service_charges_updated: service_charge_changes(provider, scraped, current_charges),
          unchanged: keys.select { |key| current.key?(key) } - updated.keys,
          written: false
        )
      end

      def ensure_long_context_pricing_kept!(provider, active, current)
        threshold = LlmCostTracker::Pricing::Registry::CONTEXT_THRESHOLD_KEY
        dropped = active.filter_map do |id, scraped_fields|
          key = registry_key(provider, id)
          key if current.dig(key, threshold) && !scraped_fields.key?(threshold)
        end
        raise Error, "refusing to drop long-context pricing for #{dropped.join(', ')}" if dropped.any?
      end

      def removed_keys(provider, active, deprecated, current)
        legacy = active.keys.select { |id| bare?(id) && current.key?(id) }
        retired = deprecated.flat_map { |id| bare?(id) ? [registry_key(provider, id), id] : registry_key(provider, id) }
        (legacy + retired.select { |key| current.key?(key) }).uniq
      end

      def model_updates(provider, active, current)
        active.each_with_object({}) do |(id, scraped_fields), updates|
          key = registry_key(provider, id)
          next unless current.key?(key)

          field_changes = changes(provider_model_fields(current.fetch(key)), scraped_fields)
          updates[key] = field_changes if field_changes.any?
        end
      end

      def service_charge_changes(provider, scraped, current_charges)
        existing = current_charges.fetch(provider, {})
        scraped.service_charges.empty? ? {} : changes(existing, scraped.service_charges)
      end

      def changes(before, after)
        (before.keys | after.keys).sort.each_with_object({}) do |key, changes|
          changes[key] = { "from" => before[key], "to" => after[key] } if before[key] != after[key]
        end
      end

      def listed_keys(plan, provider, held)
        held_keys = held.keys.map { |id| registry_key(provider, id) }
        plan.added + plan.updated.keys + plan.unchanged + plan.removed + held_keys
      end

      def with_absences(plan, provider, missing, absent_since)
        dates = missing.to_h { |key| [key, absent_since.fetch(key, @today.iso8601)] }
        expired = dates.select { |_key, date| @today - Date.iso8601(date) >= PRUNE_AFTER_DAYS }.keys
        before = absent_since.select { |key, _| key.start_with?("#{provider}/") }
        plan.with(removed: plan.removed + expired, absent: changes(before, dates.except(*expired)))
      end

      def stale_source_urls?(registry, source_urls)
        source_urls && registry.dig("metadata", "source_urls") != source_urls
      end

      def updated_registry(provider, scraped, registry, plan, source_urls)
        updated = registry.merge(
          "metadata" => written_metadata(registry, plan, source_urls),
          "models" => written_models(provider, registry.fetch("models", {}), scraped, plan.removed)
        )
        charges = registry.fetch("service_charges", {})
        charges = charges.merge(provider => scraped.service_charges) if scraped.service_charges.any?
        updated["service_charges"] = charges if registry.key?("service_charges") || charges.any?
        updated
      end

      def written_metadata(registry, plan, source_urls)
        metadata = registry.fetch("metadata", {}).merge("updated_at" => @today.iso8601)
        metadata["source_urls"] = source_urls if source_urls
        absent = metadata.fetch("absent_since", {}).merge(plan.absent.transform_values { |dates| dates["to"] }).compact
        absent.empty? ? metadata.except("absent_since") : metadata.merge("absent_since" => absent)
      end

      def written_models(provider, current, scraped, removed)
        models = current.except(*removed)
        scraped.models.except(*scraped.deprecated_models).each do |id, scraped_fields|
          key = registry_key(provider, id)
          existing = models[key] || (current[id] if bare?(id)) || {}
          models.delete(id) if bare?(id)
          models[key] = preserved_model_fields(existing).merge(scraped_fields)
        end
        models
      end

      def provider_model_fields(entry)
        entry.reject { |field, _value| preserved_model_field?(field) }
      end

      def preserved_model_fields(entry)
        entry.select { |field, _value| preserved_model_field?(field) }
      end

      def preserved_model_field?(field)
        field.start_with?("_") && !LlmCostTracker::Pricing::Registry::METADATA_KEYS.include?(field)
      end

      def registry_key(provider, model_id)
        "#{provider}/#{model_id}"
      end

      def bare?(model_id)
        !model_id.to_s.include?("/")
      end
    end
  end
end
