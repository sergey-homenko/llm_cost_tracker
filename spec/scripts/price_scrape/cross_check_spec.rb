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
  let(:models_dev) { JSON.parse(File.read("spec/fixtures/scrape/models_dev.json")) }
  let(:check) do
    described_class.new(registry: registry, catalogue: catalogue, models_dev: models_dev, acknowledged: acknowledged,
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
    expect(check.findings).to include("- gemini: gemini/gemini-3.8-flash\n", "- deepseek: deepseek/deepseek-flash\n")
    expect(check.findings[/^### LiteLLM-only models of fully scraped providers\n\n(.*?)\n\n/m, 1])
      .not_to match(/^- (?:groq|mistral):/)
  end

  it "lists the Mistral and Groq models only LiteLLM prices that models.dev does not confirm, which go unwritten" do
    unconfirmed = check.findings[/^- mistral: (.*)$/, 1].split(", ")

    expect(check.findings).to include(
      "### LiteLLM-only models models.dev prices differently (not written)\n\n" \
      "- LiteLLM 0.1/0.4, models.dev 0.1/0.3: mistral/voxtral-small-latest\n" \
      "- LiteLLM 0.3/0.3, models.dev 0.15/0.15: mistral/open-mistral-nemo\n" \
      "- LiteLLM 0.6/0.8, models.dev 0.59/0.79: groq/llama-3.3-70b-versatile\n"
    )
    expect(unconfirmed).to include("mistral/codestral-mamba-latest", "mistral/mistral-embed-2312")
    expect(unconfirmed).not_to include("mistral/pixtral-large-latest", "mistral/labs-leanstral-1-5",
                                       "mistral/mistral-ocr-latest")
    expect(check.findings).not_to include("groq/qwen/qwen3.8-27b", "groq/llama-guard-3-8b")
  end

  it "gates the LiteLLM rows and absent keys the registry holds again, as the runner does" do
    prices = { "input" => 0.1, "_source" => "litellm" }
    rows = { "mistral/mistral-embed" => prices, "mistral/mistral-tiny" => prices.except("_source") }
    gated = registry.merge("metadata" => { "absent_since" => { "mistral/mistral-tiny" => "2026-10-01" } },
                           "models" => registry["models"].merge(rows))
    models_dev["mistral"]["models"]["mistral-embed"]["cost"]["input"] = 0.12
    check = described_class.new(registry: gated, catalogue: catalogue, models_dev: models_dev)

    expect(check.findings).to include("- LiteLLM 0.1/0.0, models.dev 0.12/0.0: mistral/mistral-embed\n")
    expect(check.findings[/^- mistral: (.*)$/, 1].split(", ")).to include("mistral/mistral-tiny")
  end

  it "lists tiers and data residency LiteLLM prices on models the registry covers without them" do
    ultrafast = converted.fetch("openai/gpt-6-astra").keys.grep(/ultrafast/).sort.map { |field| "`#{field}`" }

    expect(check.findings).to include("- #{ultrafast.join(', ')}: openai/gpt-6-astra")
    expect(check.findings).to include("- `data_residency_*` (x1.1): openai/gpt-realtime-2.1")
    expect(check.findings).not_to include("anthropic/claude-opus-4-8")
  end

  it "lists unknown LiteLLM fields and prices the registry cannot represent" do
    expect(check.findings).to include("- `citation_cost_per_token` (1): perplexity/sonar-deep-research")
    expect(check.findings).to include("- reasoning tokens priced apart from output: perplexity/sonar-deep-research")
  end

  it "compares off-peak windows like rates, and lists windows that differ as a difference" do
    flash = converted.fetch("deepseek/deepseek-flash")
    weekend = [{ "weekdays" => [6, 7], "hours_utc" => ["00:00-24:00"] }]
    models = { "deepseek/deepseek-flash" => flash.merge("_off_peak_windows" => weekend) }
    check = described_class.new(registry: registry.merge("models" => models), catalogue: catalogue)

    expect(check.summary).to include("| deepseek | #{flash.size} | #{flash.size - 1} | 1 | 0 | 0 |")
    expect(check.findings).to include(
      "| deepseek/deepseek-flash | `_off_peak_windows` | #{weekend.to_json} | " \
      "#{flash['_off_peak_windows'].to_json} |  |"
    )
    expect(described_class.new(registry: registry.merge("models" => models.merge("deepseek/deepseek-flash" => flash)),
                               catalogue: catalogue).findings).not_to include("deepseek")
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
      { "openai/gpt-4o.input" => "Known.", "openai/gpt-realtime-2.1" => "Whole model.", "openai/gone.input" => "Old.",
        "mistral/open-mistral-nemo" => "Retired.", "mistral/codestral-mamba-latest" => "Retired." }
    end

    it "moves them to a collapsed section of the report and flags acknowledgements that match nothing" do
      expect(check.findings).not_to include("openai/gpt-4o |", "openai/gpt-realtime-2.1\n", "mistral/open-mistral-nemo",
                                            "mistral/codestral-mamba-latest")
      expect(check.findings)
        .to include("### Stale acknowledgements\n\n- `openai/gone.input` no longer matches a finding")
      expect(check.report("a" * 40)).to include(
        "<details>\n<summary>Acknowledged (4)</summary>\n\n- `mistral/codestral-mamba-latest`: Retired.\n" \
        "- `mistral/open-mistral-nemo`: Retired.\n- `openai/gpt-4o.input`: Known.\n" \
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
    litellm = LlmCostTracker::Pricing::Scrape::Providers::Litellm
    stub_request(:get, format(litellm::PRICES_URL, sha))
      .to_return(status: 200, body: JSON.generate(catalogue.slice("gpt-4o", "gpt-6-astra", "mistral/mistral-tiny")))
    stub_request(:get, litellm::MODELS_DEV_URL).to_return(status: 200, body: JSON.generate(models_dev))
    Dir.mktmpdir do |dir|
      prices, acks, notes, report, issue = %w[prices.json acks.yml notes.md report.md issue.md].map do |name|
        File.join(dir, name)
      end
      File.write(prices, JSON.generate(registry))
      File.write(acks, "openai/gpt-4o.input: Known.\n")
      File.write(notes, "- `openai/gpt-7`: undecided\n")

      described_class.run(report_path: report, issue_path: issue, registry_path: prices, acknowledged_path: acks,
                          notes_path: notes, sha: sha)

      expect(File.read(report)).to start_with("## Cross-source check (LiteLLM aaaaaaaa)\n\n| provider |")
      expect(File.read(report)).to include("- `openai/gpt-4o.input`: Known.")
      expect(File.read(issue)).to start_with("### Scraper notes\n\n- `openai/gpt-7`: undecided\n\n" \
                                             "### LiteLLM-only models models.dev does not list (not written)\n\n" \
                                             "- mistral: mistral/mistral-tiny\n\n" \
                                             "### LiteLLM-only fields on covered models")
      expect(File.read(prices)).to eq(JSON.generate(registry))
    end
  end
end
