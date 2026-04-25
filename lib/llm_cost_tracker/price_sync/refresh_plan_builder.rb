# frozen_string_literal: true

module LlmCostTracker
  module PriceSync
    class RefreshPlanBuilder
      def initialize(sources:, loader: RegistryLoader.new)
        @sources = sources
        @loader = loader
      end

      def call(path:, seed_path:, fetcher:, today:)
        path = path.to_s
        registry = loader.call(path: path, seed_path: seed_path)
        current_models = registry.fetch("models", {})
        source_results, failed_sources = fetch_all(current_models, fetcher)
        merged, discrepancies = Merger.new.merge(source_results)
        validated = Validator.new.validate_batch(merged, existing_registry: current_models)
        updated_models = apply_changes(current_models, validated.accepted, today)

        PriceSync::RefreshPlan.new(
          path: path,
          registry: registry,
          updated_registry: registry.merge(
            "metadata" => updated_metadata(
              registry["metadata"],
              today,
              refresh_succeeded: source_results.any? { |_source, result| result.prices.any? },
              source_results: source_results
            ),
            "models" => updated_models
          ),
          accepted: validated.accepted,
          changes: price_changes(current_models, updated_models),
          orphaned_models: compute_orphaned(current_models, merged.keys, source_results),
          failed_sources: failed_sources,
          discrepancies: discrepancies,
          rejected: validated.rejected,
          flagged: validated.flagged,
          sources_used: source_usage(source_results),
          source_results: source_results
        )
      end

      private

      attr_reader :sources, :loader

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

      def compute_orphaned(current_models, merged_models, source_results)
        return [] if source_results.empty?

        seed_models(current_models).keys.reject do |model|
          manual_model?(current_models[model]) || merged_models.include?(model)
        end.sort
      end

      def seed_models(current_models)
        normalize_models(current_models).transform_values do |entry|
          next entry if entry.key?("_source")

          entry.merge("_source" => "seed")
        end
      end

      def normalize_models(models)
        normalize_hash(models).each_with_object({}) do |(model, entry), normalized|
          normalized[model.to_s] = normalize_hash(entry)
        end
      end

      def normalize_hash(hash)
        return {} if hash.nil?
        raise ArgumentError, "price sync entries must be hashes" unless hash.is_a?(Hash)

        hash.each_with_object({}) do |(key, value), normalized|
          normalized[key.to_s] = value
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
          PriceSync::SourceUsage.new(prices_count: result.prices.size, source_version: result.source_version)
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

      def source_urls(source_results)
        names = source_results.keys.map(&:to_sym)
        sources.select { |source| names.include?(source.name.to_sym) }.map(&:url)
      end
    end
  end
end
