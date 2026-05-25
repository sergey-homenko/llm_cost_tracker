# frozen_string_literal: true

require "spec_helper"
require "price_scrape/providers/openrouter"

RSpec.describe LlmCostTracker::Pricing::Scrape::Providers::Openrouter do
  let(:payload) do
    {
      data: [
        { id: "openai/gpt-4o", name: "GPT-4o",
          pricing: { prompt: "0.0000025", completion: "0.00001",
                     input_cache_read: "0.00000125" } },
        { id: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4",
          pricing: { prompt: "0.000003", completion: "0.000015",
                     input_cache_read: "0.0000003", input_cache_write: "0.00000375" } },
        { id: "google/gemini-2.5-flash", name: "Gemini 2.5 Flash",
          pricing: { prompt: "0.0000003", completion: "0.0000025" } },
        { id: "meta-llama/llama-3.3-70b-instruct", name: "Llama 3.3 70B",
          pricing: { prompt: "0.00000023", completion: "0.0000004" } },
        { id: "free/model", name: "Free Model",
          pricing: { prompt: "0", completion: "0" } }
      ]
    }.to_json
  end

  it "converts OpenRouter per-token prices to per-million for input/output and cache fields" do
    stub_const("#{described_class}::MIN_MODELS_EXPECTED", 4)
    result = described_class.new.call(html: payload)

    expect(result.models).to include(
      "openai/gpt-4o" => a_hash_including("input" => 2.5, "output" => 10.0, "cache_read_input" => 1.25),
      "anthropic/claude-sonnet-4" => a_hash_including(
        "input" => 3.0, "output" => 15.0,
        "cache_read_input" => 0.3, "cache_write_input" => 3.75
      ),
      "google/gemini-2.5-flash" => a_hash_including("input" => 0.3, "output" => 2.5),
      "meta-llama/llama-3.3-70b-instruct" => a_hash_including("input" => 0.23, "output" => 0.4)
    )
  end

  it "skips zero-priced (free-tier) entries so they don't pollute the registry with 0.0 rates" do
    stub_const("#{described_class}::MIN_MODELS_EXPECTED", 4)
    result = described_class.new.call(html: payload)

    expect(result.models).not_to have_key("free/model")
  end

  it "raises when the API returns fewer models than the minimum threshold (catches API breakage)" do
    expect do
      described_class.new.call(html: payload)
    end.to raise_error(described_class::Error, /expected at least 30 models/)
  end

  it "raises on invalid JSON so a broken endpoint doesn't silently wipe the registry" do
    expect do
      described_class.new.call(html: "<html>not json</html>")
    end.to raise_error(described_class::Error, /invalid JSON/)
  end
end
