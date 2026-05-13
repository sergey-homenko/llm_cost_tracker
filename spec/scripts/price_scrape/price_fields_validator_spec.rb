# frozen_string_literal: true

require "spec_helper"
require_relative "../../../scripts/price_scrape/price_fields_validator"

RSpec.describe LlmCostTracker::Pricing::Scrape::PriceFieldsValidator do
  let(:error_class) { Class.new(StandardError) }
  let(:base_models) do
    {
      "claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 },
      "claude-sonnet-4-6" => { "input" => 3.0, "output" => 15.0 }
    }
  end

  it "passes when every anchor model is present" do
    expect do
      described_class.call(base_models, minimum: 2, maximum: 1000.0,
                           anchors: %w[claude-opus-4-7], error_class: error_class)
    end.not_to raise_error
  end

  it "raises when an anchor model is missing from the parsed scrape" do
    models_without_anchor = base_models.except("claude-opus-4-7")
    expect do
      described_class.call(models_without_anchor, minimum: 1, maximum: 1000.0,
                           anchors: %w[claude-opus-4-7], error_class: error_class)
    end.to raise_error(error_class, /anchor models missing from scrape: claude-opus-4-7/)
  end

  it "does not check anchors when none are configured" do
    expect do
      described_class.call(base_models, minimum: 2, maximum: 1000.0, error_class: error_class)
    end.not_to raise_error
  end
end
