# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "yaml"
require "price_scrape/cross_check"

RSpec.describe LlmCostTracker::Pricing::Scrape::CrossCheck do
  let(:catalogue) { JSON.parse(File.read("spec/fixtures/scrape/litellm_prices.json", encoding: "utf-8")) }
  let(:converted) { LlmCostTracker::Pricing::Scrape::Providers::Litellm.convert(catalogue).models }
  let(:registry) do
    {
      "service_charges" => { "openai" => { "web_search_request" => 25.0 },
                             "anthropic" => { "web_search_request" => 10.0 } },
      "models" => {
        "openai/gpt-4o" => converted.fetch("openai/gpt-4o").merge("input" => 2.4),
        "openai/gpt-6-astra" => converted.fetch("openai/gpt-6-astra")
                                         .reject { |field, _| field.include?("ultrafast") || field.start_with?("_") }
                                         .merge("data_residency_input" => 11.0),
        "openai/gpt-realtime-2.1" => converted.fetch("openai/gpt-realtime-2.1"),
        "anthropic/claude-opus-4-8" => converted.fetch("anthropic/claude-opus-4-8").except("batch_cache_read_input")
                                                .merge("data_residency_input" => 5.5),
        "openrouter/qwen/qwen3-max" => converted.fetch("openrouter/qwen/qwen3-max").merge("input" => 9.0)
      }
    }
  end
  let(:acknowledged) { {} }
  let(:check) do
    described_class.new(registry: registry, catalogue: catalogue, acknowledged: acknowledged,
                        today: Date.new(2026, 10, 4))
  end

  it "counts per provider the values both sources price, deriving tier rates the registry leaves to runtime" do
    compared = converted.fetch("anthropic/claude-opus-4-8").size

    expect(check.summary).to include("| anthropic | #{compared} | #{compared} | 0 | 0 | 0 |")
    expect(check.summary).to match(/^\| openai \| \d+ \| \d+ \| 1 \| \d+ \| 0 \|$/)
    expect(check.summary).to match(/^\| openrouter \| \d+ \| \d+ \| 1 \| 0 \| 0 \|$/)
  end

  it "lists values more than 1% apart, keeping the official one" do
    expect(check.findings).to include("| openai/gpt-4o | `input` | 2.4 | 2.5 | +4% |")
  end

  it "compares neither long-context thresholds nor OpenAI's search fee, which LiteLLM prices as the preview tool" do
    expect(check.findings).not_to include("_context_price_threshold_tokens", "web_search_request")
  end

  it "lists LiteLLM-only models of fully scraped providers, without dated twins, retired or uncaptured models" do
    openai = check.findings[/^- openai: (.*)$/, 1].split(", ")

    expect(openai).to include("openai/gpt-4o-transcribe", "openai/tts-1", "openai/whisper-1")
    expect(openai).not_to include("openai/gpt-4o-2024-08-06", "openai/computer-use-preview", "openai/gpt-realtime-2.1")
    expect(check.findings).to include("- gemini: gemini/gemini-3.8-flash\n")
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
    expect(check.findings).to include("- time-of-day prices (off_peak_pricing): deepseek/deepseek-flash")
  end

  it "keeps OpenRouter, priced from its own live API and billed amounts, out of the findings" do
    expect(check.findings).not_to include("openrouter/")
  end

  it "keeps the Gemini models the scraper leaves out of capture scope out of every finding" do
    catalogue["gemini/gemini-3.8-live"]["input_cost_per_video_per_second"] = 0.0001

    expect(check.findings).not_to include("gemini-3.8-live")
  end

  context "with acknowledged findings" do
    let(:acknowledged) do
      { "openai/gpt-4o.input" => "Known.", "openai/gpt-realtime-2.1" => "Whole model.", "openai/gone.input" => "Old." }
    end

    it "moves them to a collapsed section of the report and flags acknowledgements that match nothing" do
      expect(check.findings).not_to include("openai/gpt-4o |", "openai/gpt-realtime-2.1\n")
      expect(check.findings)
        .to include("### Stale acknowledgements\n\n- `openai/gone.input` no longer matches a finding")
      expect(check.report("a" * 40)).to include(
        "<details>\n<summary>Acknowledged (2)</summary>\n\n- `openai/gpt-4o.input`: Known.\n" \
        "- `openai/gpt-realtime-2.1`: Whole model.\n\n</details>"
      )
    end
  end

  it "finds nothing when the sources agree" do
    agreeing = catalogue.slice("gpt-4o", "gemini/gemini-3.8-flash")
    models = converted.slice("openai/gpt-4o", "gemini/gemini-3.8-flash")
    check = described_class.new(registry: registry.merge("models" => models), catalogue: agreeing)

    expect(check.findings).to eq("")
    expect(check.report("a" * 40)).not_to include("<details>")
  end

  it "keeps a one-line reason for every acknowledged finding" do
    expect(YAML.safe_load_file(described_class::ACKNOWLEDGED_PATH))
      .to all(satisfy { |key, reason| key.include?("/") && reason.is_a?(String) && !reason.include?("\n") })
  end

  it "writes the report pinned to a LiteLLM commit and the issue body, and never writes the registry" do
    sha = "a" * 40
    stub_request(:get, format(described_class::PRICES_URL, sha))
      .to_return(status: 200, body: JSON.generate(catalogue.slice("gpt-4o", "gpt-6-astra")))
    Dir.mktmpdir do |dir|
      prices, acks, report, issue = %w[prices.json acks.yml report.md issue.md].map { |name| File.join(dir, name) }
      File.write(prices, JSON.generate(registry))
      File.write(acks, "openai/gpt-4o.input: Known.\n")

      described_class.run(report_path: report, issue_path: issue, registry_path: prices, acknowledged_path: acks,
                          sha: sha)

      expect(File.read(report)).to start_with("## Cross-source check (LiteLLM aaaaaaaa)\n\n| provider |")
      expect(File.read(report)).to include("- `openai/gpt-4o.input`: Known.")
      expect(File.read(issue)).to start_with("### LiteLLM-only fields on covered models")
      expect(File.read(prices)).to eq(JSON.generate(registry))
    end
  end
end
