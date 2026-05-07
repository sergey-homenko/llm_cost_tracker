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

  describe "attribution masking" do
    it "renders provider_api_key_id and workspace ids with the trailing characters only" do
      summary = helper_object.attribution_summary(
        provider_project_id: "proj_alpha",
        provider_api_key_id: "sk-live-1234567890ABCDEF",
        provider_workspace_id: "wrkspc_secret_abcdef"
      )

      expect(summary).to eq(
        "provider_project_id=proj_alpha, provider_api_key_id=***CDEF, provider_workspace_id=***cdef"
      )
    end

    it "leaves a short sensitive value unmasked rather than exposing one or two characters" do
      expect(helper_object.mask_secret("ab")).to eq("ab")
    end
  end
end
