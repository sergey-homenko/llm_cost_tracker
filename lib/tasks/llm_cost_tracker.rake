# frozen_string_literal: true

require "fileutils"

# rubocop:disable Metrics/BlockLength
namespace :llm_cost_tracker do
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
      "Refresh the configured pricing file from the maintained LLM Cost Tracker price snapshot. " \
      "Use PREVIEW=1 to preview, URL=... to override the source, or OUTPUT=path/to/file.json."
    )
    task :refresh do
      Rake::Task["environment"].invoke if Rake::Task.task_defined?("environment")
      require_relative "../llm_cost_tracker"

      output_path = price_refresh_output_path
      source_url = LlmCostTracker::PriceSync.configured_remote_url
      preview = ENV["PREVIEW"] == "1"
      result = LlmCostTracker::PriceSync.refresh(
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
      print_changes(result.changes)
    end

    desc "Compare the current pricing file with the maintained LLM Cost Tracker price snapshot."
    task :check do
      Rake::Task["environment"].invoke if Rake::Task.task_defined?("environment")
      require_relative "../llm_cost_tracker"

      output_path = price_refresh_output_path
      source_url = LlmCostTracker::PriceSync.configured_remote_url
      result = LlmCostTracker::PriceSync.check(path: output_path, url: source_url)

      puts "llm_cost_tracker: checked pricing file #{result.path}"
      puts "  source: #{result.source_url}"
      puts "  version: #{result.source_version.inspect}" if result.source_version
      print_changes(result.changes)
      puts "  pricing is up to date" if result.up_to_date
      abort("llm_cost_tracker: pricing check failed") unless result.up_to_date
    end

    desc "Explain how a provider/model price is matched. Use PROVIDER=... MODEL=..."
    task :explain do
      Rake::Task["environment"].invoke if Rake::Task.task_defined?("environment")
      require_relative "../llm_cost_tracker"

      explanation = price_explanation_from_env
      puts "llm_cost_tracker: #{explanation.message}"
      print_price_explanation(explanation)
      abort("llm_cost_tracker: price is incomplete or unknown") unless explanation.complete?
    end
  end
end
# rubocop:enable Metrics/BlockLength

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

def price_refresh_output_path
  path = LlmCostTracker::PriceSync.configured_output_path
  FileUtils.mkdir_p(File.dirname(path))
  path
end

def price_explanation_from_env
  provider = ENV["PROVIDER"].to_s.strip
  model = ENV["MODEL"].to_s.strip
  abort("llm_cost_tracker: use PROVIDER=... MODEL=...") if provider.empty? || model.empty?

  LlmCostTracker::Pricing.explain(
    provider: provider,
    model: model,
    pricing_mode: ENV.fetch("PRICING_MODE", nil),
    input_tokens: ENV.fetch("INPUT_TOKENS", 1).to_i,
    output_tokens: ENV.fetch("OUTPUT_TOKENS", 1).to_i,
    cache_read_input_tokens: ENV.fetch("CACHE_READ_INPUT_TOKENS", 0).to_i,
    cache_write_input_tokens: ENV.fetch("CACHE_WRITE_INPUT_TOKENS", 0).to_i
  )
end

def print_price_explanation(explanation)
  return unless explanation.matched?

  puts "  source: #{explanation.source}"
  puts "  matched_key: #{explanation.matched_key}"
  puts "  matched_by: #{explanation.matched_by}"
  puts "  pricing_mode: #{explanation.pricing_mode || 'standard'}"
  explanation.effective_prices.each do |key, value|
    puts "  #{key}: #{value.nil? ? 'missing' : value}"
  end
end
