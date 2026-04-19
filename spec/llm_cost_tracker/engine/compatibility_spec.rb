# frozen_string_literal: true

require "llm_cost_tracker/engine_compatibility"
require "spec_helper"

RSpec.describe LlmCostTracker::EngineCompatibility do
  it "rejects Rails versions below 7.1 for the Engine" do
    expect do
      described_class.check_rails_version!("7.0.8")
    end.to raise_error(LlmCostTracker::Error, "LlmCostTracker::Engine requires Rails 7.1+")
  end

  it "accepts Rails 7.1 for the Engine" do
    expect do
      described_class.check_rails_version!("7.1.0")
    end.not_to raise_error
  end
end
