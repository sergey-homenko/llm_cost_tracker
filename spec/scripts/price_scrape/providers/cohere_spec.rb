# frozen_string_literal: true

require "spec_helper"
require "json"
require "price_scrape/providers/cohere"

RSpec.describe LlmCostTracker::Pricing::Scrape::Providers::Cohere do
  let(:litellm) { LlmCostTracker::Pricing::Scrape::Providers::Litellm }
  let(:catalogue) do
    chat = ->(input, output) { { "litellm_provider" => "cohere_chat", "mode" => "chat",
                                 "input_cost_per_token" => input, "output_cost_per_token" => output } }
    {
      "command-a-03-2025" => chat.call(2.5e-06, 1e-05), "command-r7b-12-2024" => chat.call(3.75e-08, 1.5e-07),
      "command-r-08-2024" => chat.call(1.5e-07, 6e-07), "c4ai-aya-expanse-32b" => chat.call(5e-07, 1.5e-06),
      "embed-multilingual-light-v3.0" => { "litellm_provider" => "cohere", "mode" => "embedding",
                                           "input_cost_per_token" => 0.0001, "output_cost_per_token" => 0.0 },
      "rerank-v3.5" => { "litellm_provider" => "cohere", "mode" => "rerank", "input_cost_per_query" => 0.002,
                         "input_cost_per_token" => 0.0, "output_cost_per_token" => 0.0 },
      "mistral/mistral-embed" => { "litellm_provider" => "mistral", "mode" => "embedding", "input_cost_per_token" => 1e-07 }
    }
  end
  let(:models_dev) do
    { "cohere" => { "models" => {
      "command-a-03-2025" => { "cost" => { "input" => 2.5, "output" => 10 } },
      "command-r7b-12-2024" => { "cost" => { "input" => 0.0375, "output" => 0.15 } },
      "command-r-08-2024" => { "cost" => { "input" => 0.2, "output" => 0.6 } },
      "c4ai-aya-expanse-32b" => { "id" => "c4ai-aya-expanse-32b" }
    } } }
  end
  let(:pages) do
    { litellm::SOURCE_URL => JSON.generate(catalogue), litellm::MODELS_DEV_URL => JSON.generate(models_dev) }
  end

  it "writes the Cohere chat rows models.dev prices within 1%, marked as LiteLLM's" do
    result = described_class.new.call(html: pages, scraped_at: "2026-10-05T06:00:00Z")

    expect(result.models).to eq(
      "command-a-03-2025" => { "input" => 2.5, "output" => 10.0, "_source" => "litellm" },
      "command-r7b-12-2024" => { "input" => 0.0375, "output" => 0.15, "_source" => "litellm" }
    )
    expect(result.notes).to be_empty
  end

  it "holds back rows models.dev prices otherwise and leaves out the embeddings and rerank it does not price" do
    gate = litellm.gate("cohere", litellm.convert(catalogue), models_dev, {}, "2026-10-05")

    expect(gate.held).to eq("command-r-08-2024" => [[0.15, 0.6], [0.2, 0.6]])
    expect(gate.unconfirmed).to contain_exactly("c4ai-aya-expanse-32b", "embed-multilingual-light-v3.0", "rerank-v3.5")
  end

  it "writes no row, and notes it, when models.dev is unreachable" do
    result = described_class.new.call(html: pages.fetch(litellm::SOURCE_URL), scraped_at: "2026-10-05T06:00:00Z")

    expect(result.models).to be_empty
    expect(result.notes).to eq(["- `cohere`: models.dev was unreachable or invalid, so no LiteLLM-only row was written"])
  end
end
