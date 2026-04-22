# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../../dummy/config/environment"

RSpec.describe "LlmCostTracker::Engine assets" do
  include_context "with mounted llm cost tracker engine"

  it "serves the fingerprinted stylesheet with immutable caching" do
    response = get("/llm-costs/assets/#{LlmCostTracker::Assets.stylesheet_filename}")
    cache_control = response.headers["cache-control"].to_s

    expect(response.status).to eq(200)
    expect(response.headers["content-type"]).to include("text/css")
    expect(cache_control).to include("public")
    expect(cache_control).to include("max-age=31536000")
    expect(cache_control).to include("immutable")
    expect(response.body).to include(".lct-app")
  end
end
