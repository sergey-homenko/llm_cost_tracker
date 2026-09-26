# frozen_string_literal: true

require "spec_helper"

require_relative "../../dummy/config/environment"

RSpec.describe "LlmCostTracker::Engine assets" do
  include_context "with mounted llm cost tracker engine"

  it "serves the fingerprinted stylesheet with immutable caching" do
    response = get("/llm-costs/assets/#{LlmCostTracker::Assets::STYLESHEET_FILENAME}")
    cache_control = response.headers["cache-control"].to_s

    expect(response.status).to eq(200)
    expect(response.headers["content-type"]).to include("text/css")
    expect(cache_control).to include("public")
    expect(cache_control).to include("max-age=31536000")
    expect(cache_control).to include("immutable")
    expect(response.body).to include(".lct-app")
  end

  it "styles the budget and coverage bars the dashboard renders" do
    css = File.read(LlmCostTracker::Assets::STYLESHEET_PATH)

    %w[lct-bar-track lct-bar-fill lct-budget-track lct-budget-fill lct-budget-marker].each do |name|
      expect(css).to match(/\.#{name}\b[^{]*\{/)
    end
  end

  it "disables caching in development so edited stylesheets are picked up immediately" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))

    response = get("/llm-costs/assets/#{LlmCostTracker::Assets::STYLESHEET_FILENAME}")

    expect(response.status).to eq(200)
    expect(response.headers["cache-control"].to_s).to include("no-store")
  end
end
