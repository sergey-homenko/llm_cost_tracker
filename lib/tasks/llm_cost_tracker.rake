# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength
namespace :llm_cost_tracker do
  desc "Check LLM Cost Tracker setup"
  task :doctor do
    Rake::Task["environment"].invoke if Rake::Task.task_defined?("environment")
    checks = LlmCostTracker::Doctor.call
    puts LlmCostTracker::Doctor.report(checks)
    abort("llm_cost_tracker: doctor found setup errors") unless LlmCostTracker::Doctor.healthy?(checks)
  end

  desc "Print an LLM cost report from ActiveRecord storage"
  task report: :environment do
    days = (ENV["DAYS"] || LlmCostTracker::Report::DEFAULT_DAYS).to_i
    puts LlmCostTracker::Report.generate(days: days)
  end

  desc "Delete llm_api_calls older than DAYS (default: 90). Use BATCH_SIZE=N to tune."
  task prune: :environment do
    days = (ENV["DAYS"] || 90).to_i
    batch_size = (ENV["BATCH_SIZE"] || LlmCostTracker::Retention::DEFAULT_BATCH_SIZE).to_i
    deleted = LlmCostTracker::Retention.prune(older_than: days, batch_size: batch_size)
    puts "llm_cost_tracker: pruned #{deleted} calls older than #{days} days"
  end

  namespace :prices do
    desc(
      "Sync built-in pricing data from LiteLLM/OpenRouter JSON sources. " \
      "Use PREVIEW=1 to preview, STRICT=1 to fail on provider errors, " \
      "or OUTPUT=path/to/file.json."
    )
    task :sync do
      Rake::Task["environment"].invoke if Rake::Task.task_defined?("environment")
      require_relative "../llm_cost_tracker"

      output_path = ENV["OUTPUT"] || LlmCostTracker.configuration.prices_file || LlmCostTracker::PriceSync::DEFAULT_OUTPUT_PATH
      strict = ENV["STRICT"] == "1" || ARGV.include?("--strict")
      result = LlmCostTracker::PriceSync.sync(
        path: output_path,
        preview: ENV["PREVIEW"] == "1",
        strict: strict
      )

      action = if ENV["PREVIEW"] == "1"
                 "previewed"
               elsif result.written
                 "updated"
               else
                 "kept"
               end

      puts "llm_cost_tracker: #{action} pricing file #{result.path}"
      print_source_usage(result.sources_used)
      print_changes(result.changes)
      print_discrepancies(result.discrepancies)
      print_issues("validator rejected", result.rejected)
      print_issues("validator flagged", result.flagged)
      print_models("orphaned models (no JSON source match)", result.orphaned_models)
      print_failures(result.failed_sources, heading: "source failures (kept existing values)")
    end

    desc "Compare the current pricing snapshot with LiteLLM/OpenRouter JSON sources and exit non-zero on drift."
    task :check do
      Rake::Task["environment"].invoke if Rake::Task.task_defined?("environment")
      require_relative "../llm_cost_tracker"

      output_path = ENV["OUTPUT"] || LlmCostTracker.configuration.prices_file || LlmCostTracker::PriceSync::DEFAULT_OUTPUT_PATH
      result = LlmCostTracker::PriceSync.check(path: output_path)

      puts "llm_cost_tracker: checked pricing file #{result.path}"
      print_source_usage(result.sources_used)
      print_changes(result.changes)
      print_discrepancies(result.discrepancies)
      print_issues("validator rejected", result.rejected)
      print_issues("validator flagged", result.flagged)
      print_models("orphaned models (no JSON source match)", result.orphaned_models)
      print_failures(result.failed_sources, heading: "source failures")
      puts "  pricing is up to date" if result.up_to_date
      abort("llm_cost_tracker: pricing check failed") unless result.up_to_date
    end
  end
end
# rubocop:enable Metrics/BlockLength

def print_source_usage(sources_used)
  return if sources_used.empty?

  puts "  sources used:"
  sources_used.each do |source, usage|
    version = usage.source_version ? ", version=#{usage.source_version.inspect}" : ""
    puts "    - #{source} (#{usage.prices_count} prices#{version})"
  end
end

def print_changes(changes)
  puts "  changed models: #{changes.size}"
  return if changes.empty?

  changes.each do |model, fields|
    puts "    - #{model}"
    fields.each do |field, values|
      puts "      #{field}: #{values['from'].inspect} -> #{values['to'].inspect}"
    end
  end
end

def print_discrepancies(discrepancies)
  return if discrepancies.empty?

  puts "  source discrepancies: #{discrepancies.size}"
  discrepancies.each do |issue|
    formatted = issue.values.map { |source, value| "#{source}=#{value.inspect}" }.join(", ")
    puts "    - #{issue.model} #{issue.field}: #{formatted}"
  end
end

def print_issues(heading, issues)
  return if issues.empty?

  puts "  #{heading}: #{issues.size}"
  issues.each do |issue|
    puts "    - #{issue.model}: #{issue.reason}"
  end
end

def print_models(heading, models)
  return if models.empty?

  puts "  #{heading}: #{models.size}"
  models.each { |model| puts "    - #{model}" }
end

def print_failures(failed_sources, heading:)
  return if failed_sources.empty?

  puts "  #{heading}: #{failed_sources.size}"
  failed_sources.each do |source, message|
    puts "    - #{source}: #{message}"
  end
end
