# frozen_string_literal: true

require "bundler/setup"
require "webmock/rspec"
require "llm_cost_tracker"

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

  config.before(:each) do
    LlmCostTracker.reset_configuration!
    LlmCostTracker::Parsers::Registry.reset!
  end
end
