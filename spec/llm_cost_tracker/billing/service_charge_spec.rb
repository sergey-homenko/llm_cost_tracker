# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Billing::ServiceCharge do
  it "rejects partial service charge cost status" do
    expect do
      described_class.build(
        component: :web_search_request,
        quantity: 1,
        cost_status: LlmCostTracker::Billing::CostStatus::PARTIAL
      )
    end.to raise_error(LlmCostTracker::Error, /Invalid service charge cost_status/)
  end
end
