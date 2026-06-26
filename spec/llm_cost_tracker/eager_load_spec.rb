# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../dummy/config/environment"

RSpec.describe "LlmCostTracker eager load" do
  it "force-loads every gem file the way a production boot does, without raising" do
    expect do
      Rails.application.eager_load!
      LlmCostTracker::Engine.eager_load!
    end.not_to raise_error
  end
end
