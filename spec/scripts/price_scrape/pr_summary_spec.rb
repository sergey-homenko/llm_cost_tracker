# frozen_string_literal: true

require "spec_helper"
require "price_scrape/pr_summary"

RSpec.describe LlmCostTracker::Pricing::Scrape::PrSummary do
  let(:before) do
    {
      "metadata" => { "absent_since" => {} },
      "models" => {
        "openai/gpt-6" => { "input" => 2.0, "output" => 8.0 },
        "openai/gpt-5" => { "input" => 1.25, "output" => 10.0 },
        "openrouter/qwen/qwen3-max" => { "input" => 1.2, "output" => 6.0 }
      },
      "service_charges" => { "openai" => { "web_search_request" => 25.0 } }
    }
  end

  def summary(after, log: "")
    described_class.new(before: before, after: after, log: log)
  end

  def with_models(models, metadata = before["metadata"])
    before.merge("metadata" => metadata, "models" => before["models"].merge(models))
  end

  it "calls OpenRouter-only churn safe to merge" do
    result = summary(with_models({ "openrouter/qwen/qwen3-max" => { "input" => 1.0, "output" => 6.0 } }))

    expect(result.verdict).to eq(:safe)
    expect(result.title).to eq("Refresh prices: safe to merge")
    expect(result.markdown).to include("## ✅ Safe to merge", "Only openrouter prices moved", "| openrouter | 1 | 0 | 0 | 0 |")
  end

  it "asks for a review of official price changes, new and removed official models, and failed scrapers" do
    after = with_models({ "openai/gpt-6" => { "input" => 1.5, "output" => 6.0 }, "openai/gpt-7" => { "input" => 5.0 } })
    after["models"].delete("openai/gpt-5")
    result = summary(after, log: "[groq] FAILED: LlmCostTracker::Error: table not found\n")

    expect(result.verdict).to eq(:review)
    expect(result.title).to eq("Refresh prices: review before merging")
    expect(result.markdown).to include(
      "Official prices changed", "`groq` failed to scrape",
      "`openai/gpt-6`: input 2.0 → 1.5 (-25%), output 8.0 → 6.0 (-25%)",
      "`openai/gpt-7`: input 5.0", "### Removed official models\n\n- `openai/gpt-5`"
    )
  end

  it "leads a new model with its base rates and threshold, and lists the ones LiteLLM prices apart" do
    after = with_models(
      "anthropic/claude-haiku-5-5" => { "_context_price_threshold_tokens" => 100_000, "batch_input" => 0.05,
                                        "cache_read_input" => 0.01, "input" => 0.1, "output" => 0.5 },
      "mistral/voxtral-small-2507" => { "_source" => "litellm", "batch_input" => 0.05, "input" => 0.1, "output" => 0.4 }
    )

    expect(summary(after).markdown).to include(
      "### New official models\n\n- `anthropic/claude-haiku-5-5`: input 0.1, output 0.5, cache_read_input 0.01, " \
      "_context_price_threshold_tokens 100000\n",
      "### New models priced from LiteLLM\n\n- `mistral/voxtral-small-2507`: input 0.1, output 0.4\n"
    )
  end

  it "flags changes users' prices:refresh refuses" do
    result = summary(with_models({ "openai/gpt-6" => { "input" => 0.0, "output" => 8.0 } }))

    expect(result.verdict).to eq(:red)
    expect(result.title).to eq("Refresh prices: do not merge yet")
    expect(result.markdown).to include("## 🛑 Do not merge yet", "### Red flags", "`openai/gpt-6 input: 2.0 -> 0.0`")
  end

  it "lists official service charge changes and models no longer listed upstream" do
    after = with_models({}, { "absent_since" => { "openrouter/qwen/qwen3-max" => "2026-10-06" } })
    after["service_charges"] = { "openai" => { "web_search_request" => 30.0 } }
    markdown = summary(after).markdown

    expect(markdown).to include("`openai.web_search_request`: 25.0 → 30.0 (+20%)",
                                "1 models are no longer listed upstream", "| openrouter | 0 | 0 | 0 | 1 |")
  end

  it "caps long lists" do
    added = (1..35).to_h { |index| ["openai/model-#{index}", { "input" => 1.0 }] }

    expect(summary(with_models(added)).markdown).to include("- and 5 more in the diff below")
  end
end
