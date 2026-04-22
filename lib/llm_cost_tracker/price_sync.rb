# frozen_string_literal: true

require "date"

require_relative "price_sync/fetcher"
require_relative "price_sync/raw_price"
require_relative "price_sync/source"
require_relative "price_sync/source_result"
require_relative "price_sync/registry_loader"
require_relative "price_sync/registry_writer"
require_relative "price_sync/refresh_plan_builder"
require_relative "price_sync/model_catalog"
require_relative "price_sync/merger"
require_relative "price_sync/validator"
require_relative "price_sync/sources/litellm"
require_relative "price_sync/sources/open_router"

module LlmCostTracker
  module PriceSync
    DEFAULT_OUTPUT_PATH = PriceRegistry::DEFAULT_PRICES_PATH

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
        plan = RefreshPlanBuilder.new(sources: sources).call(
          path: path,
          seed_path: seed_path,
          fetcher: fetcher,
          today: today
        )
        raise Error, strict_failure_message(plan) if strict_sync_failure?(plan, strict: strict)

        written = !preview && plan.refresh_succeeded?
        RegistryWriter.new.call(path: plan.path, registry: plan.updated_registry) if written

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
        plan = RefreshPlanBuilder.new(sources: sources).call(
          path: path,
          seed_path: seed_path,
          fetcher: fetcher,
          today: today
        )

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
    end
  end
end
