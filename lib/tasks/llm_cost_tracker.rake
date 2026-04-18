# frozen_string_literal: true

namespace :llm_cost_tracker do
  desc "Print an LLM cost report from ActiveRecord storage"
  task report: :environment do
    days = (ENV["DAYS"] || LlmCostTracker::Report::DEFAULT_DAYS).to_i
    puts LlmCostTracker::Report.generate(days: days)
  end
end
