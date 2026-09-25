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
    expect(response.body).to include("Updated #{LlmCostTracker::Pricing::Registry.metadata.fetch('updated_at')}")
    expect(response.body).to include("claude-haiku-4-5")
  end

  it "shows an Overrides tab and selects it as effective when pricing_overrides is set" do
    LlmCostTrackerReset.call
    LlmCostTracker.configure do |config|
      config.pricing.overrides = { "openai/gpt-4o" => { input: 2.0, output: 8.0 } }
    end

    response = get("/llm-costs/pricing")

    expect(response.status).to eq(200)
    expect(response.body).to include("Overrides")
    expect(response.body).to match(/<a [^>]*class="lct-tab lct-active"[^>]*>\s*Overrides/m)
  ensure
    LlmCostTrackerReset.call
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

  it "falls back to the effective source when source is a list or a hash" do
    LlmCostTracker.configure do |config|
      config.pricing.overrides = { "openai/gpt-4o" => { input: 2.0, output: 8.0 } }
    end

    %w[source%5B%5D=bundled source%5Bbundled%5D=1].each do |query|
      response = get("/llm-costs/pricing?#{query}")

      expect(response.status).to eq(200)
      expect(response.body).to match(/<a [^>]*class="lct-tab lct-active"[^>]*>\s*Overrides/m)
    end
  end

  it "marks pricing as the active sidebar section" do
    response = get("/llm-costs/pricing")

    expect(response.status).to eq(200)
    expect(response.body).to match(/<a [^>]*aria-current="page"[^>]*>\s*<svg[^>]*>.*?<\/svg>\s*Pricing\s*<\/a>/m)
  end

  it "rejects a list or a hash in the provider filter as a bad request" do
    [get("/llm-costs/pricing?provider%5B%5D=openai"), get("/llm-costs/pricing?provider%5Bx%5D=openai")].each do |response|
      expect(response.status).to eq(400)
      expect(response.body).to include("provider must be a single value")
    end
  end
end
