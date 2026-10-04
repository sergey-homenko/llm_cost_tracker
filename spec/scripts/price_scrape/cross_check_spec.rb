# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "price_scrape/cross_check"

RSpec.describe LlmCostTracker::Pricing::Scrape::CrossCheck do
  let(:catalogue) { JSON.parse(File.read("spec/fixtures/scrape/litellm_prices.json", encoding: "utf-8")) }
  let(:converted) { LlmCostTracker::Pricing::Scrape::Providers::Litellm.convert(catalogue).models }
  let(:registry) do
    {
      "service_charges" => %w[openai anthropic].to_h { |provider| [provider, { "web_search_request" => 10.0 }] },
      "models" => {
        "openai/gpt-4o" => converted.fetch("openai/gpt-4o").merge("input" => 2.4),
        "openai/gpt-6-astra" => converted.fetch("openai/gpt-6-astra").reject { |field, _| field.include?("ultrafast") }
                                         .merge("data_residency_input" => 11.0),
        "openai/gpt-realtime-2.1" => converted.fetch("openai/gpt-realtime-2.1"),
        "anthropic/claude-opus-4-8" => converted.fetch("anthropic/claude-opus-4-8").except("batch_cache_read_input")
                                                .merge("data_residency_input" => 5.5)
      }
    }
  end
  let(:check) { described_class.new(registry: registry, catalogue: catalogue, today: Date.new(2026, 10, 4)) }

  it "counts per provider the values both sources price, deriving tier rates the registry leaves to runtime" do
    compared = converted.fetch("anthropic/claude-opus-4-8").size

    expect(check.summary).to include("| anthropic | #{compared} | #{compared} | 0 | 0 | 0 |")
    expect(check.summary).to match(/^\| openai \| \d+ \| \d+ \| 1 \| \d+ \| 0 \|$/)
  end

  it "lists values more than 1% apart, keeping the official one" do
    expect(check.findings).to include("| openai/gpt-4o | `input` | 2.4 | 2.5 | +4% |")
  end

  it "lists LiteLLM-only models of fully scraped providers, without dated twins or retired models" do
    gaps = check.findings[/^- openai: (.*)$/, 1].split(", ")

    expect(gaps).to include("openai/gpt-4o-transcribe", "openai/tts-1", "openai/whisper-1")
    expect(gaps).not_to include("openai/gpt-4o-2024-08-06", "openai/computer-use-preview", "openai/gpt-realtime-2.1")
    expect(check.findings).not_to match(/^- (?:groq|mistral|deepseek):/)
  end

  it "lists tiers and data residency LiteLLM prices on models the registry covers without them" do
    ultrafast = converted.fetch("openai/gpt-6-astra").keys.grep(/ultrafast/).sort.map { |field| "`#{field}`" }

    expect(check.findings).to include("- #{ultrafast.join(', ')}: openai/gpt-6-astra")
    expect(check.findings).to include("- `data_residency_*` (x1.1): openai/gpt-realtime-2.1")
    expect(check.findings).not_to include("anthropic/claude-opus-4-8")
  end

  it "lists unknown LiteLLM fields and prices the registry cannot represent" do
    expect(check.findings).to include("- `citation_cost_per_token` (1): perplexity/sonar-deep-research")
    expect(check.findings).to include("- several long-context thresholds: openrouter/qwen/qwen3-max")
  end

  it "finds nothing when the sources agree" do
    agreeing = catalogue.slice("gpt-4o", "gemini/gemini-3.8-flash")
    models = converted.slice("openai/gpt-4o", "gemini/gemini-3.8-flash")
    check = described_class.new(registry: registry.merge("models" => models), catalogue: agreeing)

    expect(check.findings).to eq("")
    expect(check.summary).to include("| openai | #{models.fetch('openai/gpt-4o').size} |")
  end

  it "writes the report pinned to a LiteLLM commit and the issue body, and never writes the registry" do
    sha = "a" * 40
    stub_request(:get, format(described_class::PRICES_URL, sha))
      .to_return(status: 200, body: JSON.generate(catalogue.slice("gpt-4o", "gpt-6-astra")))
    Dir.mktmpdir do |dir|
      prices, report, issue = %w[prices.json report.md issue.md].map { |name| File.join(dir, name) }
      File.write(prices, JSON.generate(registry))

      described_class.run(report_path: report, issue_path: issue, registry_path: prices, sha: sha)

      expect(File.read(report)).to start_with("## Cross-source check (LiteLLM aaaaaaaa)\n\n| provider |")
      expect(File.read(issue)).to start_with("### Values that differ by more than 1% (official kept)")
      expect(File.read(report)).to end_with(File.read(issue))
      expect(File.read(prices)).to eq(JSON.generate(registry))
    end
  end
end
