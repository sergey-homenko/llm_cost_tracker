# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../dummy/config/environment"

RSpec.describe "llm_cost_tracker generators" do
  before do
    Rails.application.load_generators
  end

  it "registers the documented install and upgrade generators" do
    {
      "llm_cost_tracker:install" => "LlmCostTracker::Generators::InstallGenerator",
      "llm_cost_tracker:add_latency_ms" => "LlmCostTracker::Generators::AddLatencyMsGenerator",
      "llm_cost_tracker:add_streaming" => "LlmCostTracker::Generators::AddStreamingGenerator",
      "llm_cost_tracker:add_provider_response_id" => "LlmCostTracker::Generators::AddProviderResponseIdGenerator",
      "llm_cost_tracker:prices" => "LlmCostTracker::Generators::PricesGenerator",
      "llm_cost_tracker:upgrade_cost_precision" => "LlmCostTracker::Generators::UpgradeCostPrecisionGenerator",
      "llm_cost_tracker:upgrade_tags_to_jsonb" => "LlmCostTracker::Generators::UpgradeTagsToJsonbGenerator"
    }.each do |namespace, class_name|
      base, name = namespace.split(":", 2)

      expect(Rails::Generators.find_by_namespace(name, base)&.name).to eq(class_name)
    end
  end
end
