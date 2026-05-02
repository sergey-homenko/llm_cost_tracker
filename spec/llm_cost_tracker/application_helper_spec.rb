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
end
