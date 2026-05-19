# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../../dummy/config/environment"

RSpec.describe "LlmCostTracker::Engine pricing" do
  include_context "with mounted llm cost tracker engine"

  it "renders the pricing overview defaulting to bundled with a model row" do
    response = get("/llm-costs/pricing")

    expect(response.status).to eq(200)
    expect(response.body).to include("Pricing")
    expect(response.body).to include("Bundled")
    expect(response.body).to include("Updated 2026-05-15")
    expect(response.body).to include("claude-haiku-4-5")
  end

  it "shows an Overrides tab and selects it as effective when pricing_overrides is set" do
    LlmCostTracker.reset_configuration!
    LlmCostTracker.configure do |config|
      config.pricing_overrides = { "openai/gpt-4o" => { input: 2.0, output: 8.0 } }
    end

    response = get("/llm-costs/pricing")

    expect(response.status).to eq(200)
    expect(response.body).to include("Overrides")
    expect(response.body).to match(/<a [^>]*class="lct-tab lct-active"[^>]*>\s*Overrides/m)
  ensure
    LlmCostTracker.reset_configuration!
  end

  it "filters rows by provider within the active source" do
    response = get("/llm-costs/pricing?provider=openai")

    expect(response.status).to eq(200)
    expect(response.body).to include("openai")
    expect(response.body).not_to match(/<span class="lct-provider-dot lct-provider-dot-anthropic"><\/span>anthropic/)
  end

  it "renders an empty state when no rows match the provider filter" do
    response = get("/llm-costs/pricing?provider=nonexistent")

    expect(response.status).to eq(200)
    expect(response.body).to include("No prices for this provider")
  end

  it "honors ?source= when valid and falls back to effective when invalid" do
    response = get("/llm-costs/pricing?source=bundled")
    expect(response.body).to match(/<a [^>]*class="lct-tab lct-active"[^>]*>\s*Bundled/m)

    fallback = get("/llm-costs/pricing?source=garbage")
    expect(fallback.body).to match(/<a [^>]*class="lct-tab lct-active"[^>]*>\s*Bundled/m)
  end

  it "marks pricing as the active sidebar section" do
    response = get("/llm-costs/pricing")

    expect(response.status).to eq(200)
    expect(response.body).to match(/<a [^>]*aria-current="page"[^>]*>\s*<svg[^>]*>.*?<\/svg>\s*Pricing\s*<\/a>/m)
  end
end
