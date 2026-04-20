# frozen_string_literal: true

namespace :llm_cost_tracker do
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
end
