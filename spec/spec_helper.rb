# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require "bundler/setup"

if ENV["COVERAGE"] != "false"
  require "simplecov"
  require "simplecov-lcov"

  SimpleCov::Formatter::LcovFormatter.config do |c|
    c.report_with_single_file = true
    c.single_report_path = "coverage/lcov.info"
  end

  SimpleCov.formatter = SimpleCov::Formatter::MultiFormatter.new(
    [
      SimpleCov::Formatter::HTMLFormatter,
      SimpleCov::Formatter::LcovFormatter
    ]
  )

  SimpleCov.start do
    enable_coverage :branch
    add_filter "/spec/"
    add_filter "/gemfiles/"
    add_group "Core", "lib/llm_cost_tracker"
    add_group "Dashboard", "app"
    add_group "Generators", "lib/llm_cost_tracker/generators"
    track_files "lib/**/*.rb"
    track_files "app/**/*.rb"
  end
end

require "webmock/rspec"
require "llm_cost_tracker"
require_relative "../app/models/llm_cost_tracker/call"
require_relative "../app/models/llm_cost_tracker/call_line_item"
require_relative "../app/models/llm_cost_tracker/call_tag"
require_relative "../app/models/llm_cost_tracker/call_rollup"
require_relative "../app/models/llm_cost_tracker/provider_invoice"
require_relative "../app/models/llm_cost_tracker/ingestion/inbox_entry"
require_relative "../app/models/llm_cost_tracker/ingestion/lease"

$LOAD_PATH.unshift File.expand_path("../scripts", __dir__)

Dir[File.expand_path("support/**/*.rb", __dir__)].each { |file| require file }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.order = :random
  config.include LlmCostTrackerDatabaseSpecHelpers

  config.before(:each) do
    Rails.logger = nil
    LlmCostTracker.reset_configuration!
  end
end
