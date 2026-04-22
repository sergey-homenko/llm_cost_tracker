# frozen_string_literal: true

require "date"
require "fileutils"
require "json"
require "yaml"

require_relative "price_sync/fetcher"
require_relative "price_sync/raw_price"
require_relative "price_sync/source"
require_relative "price_sync/source_result"
require_relative "price_sync/model_catalog"
require_relative "price_sync/merger"
require_relative "price_sync/validator"
require_relative "price_sync/sources/litellm"
require_relative "price_sync/sources/open_router"

module LlmCostTracker
  # rubocop:disable Metrics/ModuleLength, Metrics/ClassLength
  module PriceSync
    DEFAULT_OUTPUT_PATH = PriceRegistry::DEFAULT_PRICES_PATH
    YAML_EXTENSIONS = %w[.yml .yaml].freeze

    SourceUsage = Data.define(:prices_count, :source_version)
    SyncResult = Data.define(
      :path,
      :updated_models,
      :changes,
      :orphaned_models,
      :failed_sources,
      :discrepancies,
      :rejected,
      :flagged,
      :sources_used,
      :written
    )
    CheckResult = Data.define(
      :path,
      :changes,
      :orphaned_models,
      :failed_sources,
      :discrepancies,
      :rejected,
      :flagged,
      :sources_used,
      :up_to_date
    )
    RefreshPlan = Data.define(
      :path,
      :registry,
      :updated_registry,
      :accepted,
      :changes,
      :orphaned_models,
      :failed_sources,
      :discrepancies,
      :rejected,
      :flagged,
      :sources_used,
      :source_results
    ) do
      def refresh_succeeded?
        source_results.any? { |_source, result| result.prices.any? }
      end

      def up_to_date?
        changes.empty? && failed_sources.empty? && rejected.empty?
      end
    end

    class << self
      def sync(path: DEFAULT_OUTPUT_PATH, seed_path: DEFAULT_OUTPUT_PATH, preview: false, strict: false,
               fetcher: Fetcher.new, today: Date.today)
        plan = build_refresh_plan(path: path, seed_path: seed_path, fetcher: fetcher, today: today)
        raise Error, strict_failure_message(plan) if strict_sync_failure?(plan, strict: strict)

        written = !preview && plan.refresh_succeeded?
        write_registry(plan.path, plan.updated_registry) if written

        SyncResult.new(
          path: plan.path,
          updated_models: plan.changes.keys.sort,
          changes: plan.changes,
          orphaned_models: plan.orphaned_models,
          failed_sources: plan.failed_sources,
          discrepancies: plan.discrepancies,
          rejected: plan.rejected,
          flagged: plan.flagged,
          sources_used: plan.sources_used,
          written: written
        )
      end

      def check(path: DEFAULT_OUTPUT_PATH, seed_path: DEFAULT_OUTPUT_PATH, fetcher: Fetcher.new, today: Date.today)
        plan = build_refresh_plan(path: path, seed_path: seed_path, fetcher: fetcher, today: today)

        CheckResult.new(
          path: plan.path,
          changes: plan.changes,
          orphaned_models: plan.orphaned_models,
          failed_sources: plan.failed_sources,
          discrepancies: plan.discrepancies,
          rejected: plan.rejected,
          flagged: plan.flagged,
          sources_used: plan.sources_used,
          up_to_date: plan.up_to_date?
        )
      end

      private

      def sources
        [Sources::Litellm.new, Sources::OpenRouter.new]
      end

      def build_refresh_plan(path:, seed_path:, fetcher:, today:)
        path = path.to_s
        registry = load_registry(path, seed_path: seed_path)
        current_models = registry.fetch("models", {})
        source_results, failed_sources = fetch_all(current_models, fetcher)
        merged, discrepancies = Merger.new.merge(source_results)
        validated = Validator.new.validate_batch(merged, existing_registry: current_models)
        updated_models = apply_changes(current_models, validated.accepted, today)
        refresh_succeeded = source_results.any? { |_source, result| result.prices.any? }

        RefreshPlan.new(
          path: path,
          registry: registry,
          updated_registry: registry.merge(
            "metadata" => updated_metadata(
              registry["metadata"],
              today,
              refresh_succeeded: refresh_succeeded,
              source_results: source_results
            ),
            "models" => updated_models
          ),
          accepted: validated.accepted,
          changes: price_changes(current_models, updated_models),
          orphaned_models: compute_orphaned(current_models, merged.keys),
          failed_sources: failed_sources,
          discrepancies: discrepancies,
          rejected: validated.rejected,
          flagged: validated.flagged,
          sources_used: source_usage(source_results),
          source_results: source_results
        )
      end

      def fetch_all(current_models, fetcher)
        results = {}
        failures = {}

        sources.each do |source|
          results[source.name.to_sym] = source.fetch(current_models: current_models, fetcher: fetcher)
        rescue Error => e
          failures[source.name.to_sym] = e.message
        end

        [results, failures]
      end

      def apply_changes(current_models, accepted, today)
        merged = seed_models(current_models)

        accepted.each do |model, price|
          next if manual_model?(merged[model])

          merged[model] = registry_entry_for(merged[model], price, today)
        end

        merged.sort.to_h
      end

      def compute_orphaned(current_models, merged_models)
        seed_models(current_models).keys.reject do |model|
          manual_model?(current_models[model]) || merged_models.include?(model)
        end.sort
      end

      def load_registry(path, seed_path:)
        source_path = File.exist?(path) ? path : seed_path.to_s
        normalize_registry(load_registry_file(source_path))
      rescue Errno::ENOENT, JSON::ParserError, Psych::Exception, ArgumentError, TypeError, NoMethodError => e
        raise Error, "Unable to load pricing registry #{source_path.inspect}: #{e.message}"
      end

      def load_registry_file(path)
        contents = File.read(path)
        return YAML.safe_load(contents, aliases: false) || {} if yaml_file?(path)

        JSON.parse(contents)
      end

      def normalize_registry(registry)
        {
          "metadata" => normalize_hash(registry.fetch("metadata", {})),
          "models" => normalize_models(registry.fetch("models", {}))
        }
      end

      def normalize_models(models)
        (models || {}).each_with_object({}) do |(model, entry), normalized|
          normalized[model.to_s] = normalize_hash(entry)
        end
      end

      def normalize_hash(hash)
        (hash || {}).each_with_object({}) do |(key, value), normalized|
          normalized[key.to_s] = value
        end
      end

      def seed_models(current_models)
        normalize_models(current_models).transform_values do |entry|
          next entry if entry.key?("_source")

          entry.merge("_source" => "seed")
        end
      end

      def manual_model?(entry)
        normalize_hash(entry)["_source"] == "manual"
      end

      def registry_entry_for(existing_entry, price, today)
        normalize_hash(existing_entry)
          .except(*PriceRegistry::PRICE_KEYS)
          .merge(price.to_registry_entry(today: today))
      end

      def updated_metadata(existing, today, refresh_succeeded:, source_results:)
        metadata = normalize_hash(existing)
        metadata["currency"] ||= "USD"
        metadata["unit"] ||= "1M tokens"
        return metadata unless refresh_succeeded

        metadata["updated_at"] = today.iso8601
        metadata["source_urls"] = source_urls(source_results)
        metadata
      end

      def source_usage(source_results)
        source_results.transform_values do |result|
          SourceUsage.new(prices_count: result.prices.size, source_version: result.source_version)
        end
      end

      def price_changes(current_models, updated_models)
        current_models = normalize_models(current_models)
        updated_models = normalize_models(updated_models)

        (current_models.keys | updated_models.keys).sort.each_with_object({}) do |model, changes|
          fields = price_field_changes(current_models[model], updated_models[model])
          changes[model] = fields if fields.any?
        end
      end

      def price_field_changes(current_entry, updated_entry)
        current_price = comparable_price(current_entry)
        updated_price = comparable_price(updated_entry)

        (current_price.keys | updated_price.keys).sort.each_with_object({}) do |field, changes|
          from = current_price[field]
          to = updated_price[field]
          next if from == to

          changes[field] = { "from" => from, "to" => to }
        end
      end

      def comparable_price(entry)
        normalize_hash(entry).slice(*PriceRegistry::PRICE_KEYS)
      end

      def strict_sync_failure?(plan, strict:)
        strict && (plan.failed_sources.any? || plan.rejected.any?)
      end

      def strict_failure_message(plan)
        messages = []
        if plan.failed_sources.any?
          details = plan.failed_sources.map { |source, message| "#{source}: #{message}" }.join(", ")
          messages << "source failures: #{details}"
        end
        if plan.rejected.any?
          details = plan.rejected.map { |issue| "#{issue.model} (#{issue.reason})" }.join(", ")
          messages << "validator rejections: #{details}"
        end
        "Price sync failed in strict mode: #{messages.join('; ')}"
      end

      def source_urls(source_results)
        names = source_results.keys.map(&:to_sym)
        sources.select { |source| names.include?(source.name.to_sym) }.map(&:url)
      end

      def write_registry(path, registry)
        FileUtils.mkdir_p(File.dirname(path))
        payload = yaml_file?(path) ? YAML.dump(registry) : "#{JSON.pretty_generate(registry)}\n"
        File.write(path, payload)
      end

      def yaml_file?(path)
        YAML_EXTENSIONS.include?(File.extname(path).downcase)
      end
    end
  end
  # rubocop:enable Metrics/ModuleLength, Metrics/ClassLength
end
