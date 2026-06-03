# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../dummy/config/environment"

RSpec.describe LlmCostTracker::ApplicationHelper do
  subject(:helper_object) do
    Class.new do
      include LlmCostTracker::ApplicationHelper
    end.new
  end

  it "calculates display percentages with a zero denominator guard" do
    expect(helper_object.coverage_percent(2, 4)).to eq(50.0)
    expect(helper_object.coverage_percent(2, 0)).to eq(0.0)
  end

  it "truncates long tag chip values at the display boundary" do
    entry = helper_object.tag_chip_entries({ feature: "x" * 100 }).first

    expect(entry).to eq(key: "feature", value: "#{'x' * 80}...")
  end

  it "parses JSON-encoded metadata strings so masking redacts provider IDs before rendering" do
    raw = { "provider_api_key_id" => "sk-live-secret-abc", "feature" => "ok" }.to_json
    masked = LlmCostTracker::Dashboard::Masking.mask_hash(helper_object.masked_metadata_hash(raw))

    expect(masked["provider_api_key_id"]).to eq("***-abc")
    expect(masked["provider_api_key_id"]).not_to include("sk-live-secret")
    expect(masked["feature"]).to eq("ok")
  end

  it "returns {} for non-JSON strings" do
    expect(helper_object.masked_metadata_hash("not json at all")).to eq({})
  end

  it "passes Hash inputs through unchanged" do
    hash = { "provider_api_key_id" => "sk-live-x" }

    expect(helper_object.masked_metadata_hash(hash)).to equal(hash)
  end

  it "returns {} for nil" do
    expect(helper_object.masked_metadata_hash(nil)).to eq({})
  end
end
