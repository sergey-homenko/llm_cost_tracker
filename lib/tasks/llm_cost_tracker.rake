# frozen_string_literal: true

require "fileutils"
require "rails/generators"

require_relative "../llm_cost_tracker/generators/llm_cost_tracker/install_generator"
require_relative "../llm_cost_tracker/pricing/sync/change_printer"

# rubocop:disable-next Metrics/BlockLength
namespace :llm_cost_tracker do
  desc "Install LLM Cost Tracker with dashboard and prices, migrate, and run doctor"
  task :setup do
    Rails::Generators.invoke("llm_cost_tracker:install", %w[--dashboard --prices --skip])
    begin
      Rake::Task["db:migrate"].invoke
    rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished => e
      abort(
        "llm_cost_tracker: database is not reachable (#{e.class}). " \
        "Start your database, run 'rails db:create db:migrate', then re-run 'rails llm_cost_tracker:setup'."
      )
    end
    Rake::Task["llm_cost_tracker:doctor"].invoke
  end

  desc "Check LLM Cost Tracker setup"
  task :doctor do
    Rake::Task["environment"].invoke if Rake::Task.task_defined?("environment")
    require_relative "../llm_cost_tracker"
    checks = LlmCostTracker::Doctor.call
    puts LlmCostTracker::Doctor.report(checks)
    abort("llm_cost_tracker: doctor found setup errors") unless LlmCostTracker::Doctor.healthy?(checks)
  end

  desc "Verify that LLM Cost Tracker can capture and persist a synthetic event"
  task :verify_capture do
    Rake::Task["environment"].invoke if Rake::Task.task_defined?("environment")
    require_relative "../llm_cost_tracker"
    checks = LlmCostTracker::CaptureVerifier.call
    puts LlmCostTracker::CaptureVerifier.report(checks)
    abort("llm_cost_tracker: capture verification failed") unless LlmCostTracker::CaptureVerifier.healthy?(checks)
  end

  desc "Print an LLM cost report from ActiveRecord storage"
  task report: :environment do
    days = (ENV["DAYS"] || LlmCostTracker::Report::Data::DEFAULT_DAYS).to_i
    puts LlmCostTracker::Report.generate(days: days)
  end

  desc "Recompute total_cost for calls with unknown pricing using the current price registry. " \
       "Use BATCH_SIZE=N to tune."
  task backfill_unknown_pricing: :environment do
    require_relative "../llm_cost_tracker/pricing/backfill"
    batch_size = (ENV["BATCH_SIZE"] || LlmCostTracker::Pricing::Backfill::DEFAULT_BATCH_SIZE).to_i
    result = LlmCostTracker::Pricing::Backfill.call(batch_size: batch_size)
    puts "llm_cost_tracker: examined #{result.examined} calls, recomputed #{result.recomputed}, " \
         "still unknown #{result.still_unknown}"
  end

  desc "Delete llm_cost_tracker_calls older than DAYS (default: 90). Use BATCH_SIZE=N to tune."
  task prune: :environment do
    days = (ENV["DAYS"] || 90).to_i
    batch_size = (ENV["BATCH_SIZE"] || LlmCostTracker::Retention::DEFAULT_BATCH_SIZE).to_i
    deleted = LlmCostTracker::Retention.prune(older_than: days, batch_size: batch_size)
    puts "llm_cost_tracker: pruned #{deleted} calls older than #{days} days"
    inbox_pruned = LlmCostTracker::Retention.prune_inbox(older_than: days)
    puts "llm_cost_tracker: pruned #{inbox_pruned} inbox entries older than #{days} days"
  end

  desc "Rebuild llm_cost_tracker_call_rollups from the calls ledger (resync the rollup cache)"
  task rebuild_rollups: :environment do
    unless LlmCostTracker::CallRollup.table_exists?
      abort("llm_cost_tracker: rollups table missing; run the call_rollups generator and migrate first")
    end
    rows = LlmCostTracker::Ledger::Rollups.rebuild!
    puts "llm_cost_tracker: rebuilt #{rows} rollup rows from the calls ledger"
  end

  desc "Copy call cost and time onto existing llm_cost_tracker_call_tags rows so per-tag " \
       "budgets count history recorded before the upgrade. Use BATCH_SIZE=N to tune."
  task backfill_tag_costs: :environment do
    unless LlmCostTracker::Budget::PerTag.columns?
      abort("llm_cost_tracker: llm_cost_tracker_call_tags is missing the cost columns; " \
            "run the upgrade_per_tag_budgets generator and migrate first")
    end
    batch_size = (ENV["BATCH_SIZE"] || LlmCostTracker::Budget::PerTag::DEFAULT_BACKFILL_BATCH).to_i
    filled = LlmCostTracker::Budget::PerTag.backfill(batch_size: batch_size)
    puts "llm_cost_tracker: filled cost and time on #{filled} tag rows"
  end

  namespace :prices do
    desc(
      "Refresh the configured pricing file from the maintained LLM Cost Tracker price snapshot. " \
      "Use PREVIEW=1 to preview, URL=... to override the source, or OUTPUT=path/to/file.json."
    )
    task :refresh do
      Rake::Task["environment"].invoke if Rake::Task.task_defined?("environment")
      require_relative "../llm_cost_tracker"

      output_path = price_refresh_output_path
      source_url = LlmCostTracker::Pricing::Sync.configured_remote_url
      preview = ENV["PREVIEW"] == "1"
      result = LlmCostTracker::Pricing::Sync.refresh(
        path: output_path,
        url: source_url,
        preview: preview
      )

      action = if preview
                 "previewed"
               elsif result.written
                 "refreshed"
               else
                 "kept"
               end

      puts "llm_cost_tracker: #{action} pricing file #{result.path}"
      puts "  source: #{result.source_url}"
      puts "  version: #{result.source_version.inspect}" if result.source_version
      LlmCostTracker::Pricing::Sync::ChangePrinter.call(result.changes)
    end

    desc "Compare the current pricing file with the maintained LLM Cost Tracker price snapshot."
    task :check do
      Rake::Task["environment"].invoke if Rake::Task.task_defined?("environment")
      require_relative "../llm_cost_tracker"

      output_path = price_refresh_output_path
      source_url = LlmCostTracker::Pricing::Sync.configured_remote_url
      result = LlmCostTracker::Pricing::Sync.check(path: output_path, url: source_url)

      puts "llm_cost_tracker: checked pricing file #{result.path}"
      puts "  source: #{result.source_url}"
      puts "  version: #{result.source_version.inspect}" if result.source_version
      LlmCostTracker::Pricing::Sync::ChangePrinter.call(result.changes)
      puts "  pricing is up to date" if result.up_to_date
      abort("llm_cost_tracker: pricing check failed") unless result.up_to_date
    end
  end
end

def price_refresh_output_path
  path = LlmCostTracker::Pricing::Sync.configured_output_path
  FileUtils.mkdir_p(File.dirname(path))
  path
end
