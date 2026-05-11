# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../dummy/config/environment"

RSpec.describe LlmCostTracker::ReconciliationHelper do
  subject(:helper_object) do
    Class.new do
      include LlmCostTracker::ReconciliationHelper
    end.new
  end

  describe "attribution masking" do
    it "renders provider project, api key, and workspace ids with the trailing characters only" do
      summary = helper_object.attribution_summary(
        provider_project_id: "proj_alpha",
        provider_api_key_id: "sk-live-1234567890ABCDEF",
        provider_workspace_id: "wrkspc_secret_abcdef"
      )

      expect(summary).to eq(
        "provider_project_id=***lpha, provider_api_key_id=***CDEF, provider_workspace_id=***cdef"
      )
    end

    it "leaves a short sensitive value unmasked rather than exposing one or two characters" do
      expect(helper_object.mask_secret("ab")).to eq("ab")
    end
  end
end
