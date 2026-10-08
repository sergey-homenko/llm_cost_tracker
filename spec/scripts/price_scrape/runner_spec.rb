# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"
require "tempfile"
require "tmpdir"
require "price_scrape/runner"

RSpec.describe LlmCostTracker::Pricing::Scrape::Runner do
  let(:io) { StringIO.new }
  let(:html) { File.read("spec/fixtures/scrape/anthropic_pricing.html", encoding: "utf-8") }
  let(:groq_models_html) { File.read("spec/fixtures/scrape/groq_models.html", encoding: "utf-8") }
  let(:groq_prompt_caching_html) { File.read("spec/fixtures/scrape/groq_prompt_caching.html", encoding: "utf-8") }
  let(:groq_flex_processing_html) { File.read("spec/fixtures/scrape/groq_flex_processing.html", encoding: "utf-8") }
  let(:groq_deprecations_html) { File.read("spec/fixtures/scrape/groq_deprecations.html", encoding: "utf-8") }
  let(:groq_batch_html) { File.read("spec/fixtures/scrape/groq_batch.html", encoding: "utf-8") }

  let(:litellm) { LlmCostTracker::Pricing::Scrape::Providers::Litellm }

  def fixture(name) = File.read("spec/fixtures/scrape/#{name}", encoding: "utf-8")

  def build_registry(haiku_entry:)
    {
      "metadata" => { "schema_version" => 1, "updated_at" => "2026-04-01" },
      "models" => { "anthropic/claude-haiku-4-5" => haiku_entry }
    }
  end

  before do
    stub_request(:get, LlmCostTracker::Pricing::Scrape::Providers::Anthropic.source_url)
      .to_return(status: 200, body: html, headers: { "Content-Type" => "text/html; charset=utf-8" })
    stub_request(:get, LlmCostTracker::Pricing::Scrape::Providers::Gemini::VERTEX_URL)
      .to_return(status: 200, body: fixture("vertex_pricing.html"))
  end

  it "fetches, parses, and applies changes for the configured provider" do
    Tempfile.create(["registry", ".json"]) do |file|
      file.write(JSON.pretty_generate(build_registry(haiku_entry: { "input" => 1.0, "output" => 5.0 })))
      file.close

      runs = described_class.new(io: io).call(providers: ["anthropic"], registry_path: file.path)

      expect(runs.size).to eq(1)
      orchestrator_result = runs.first.orchestrator
      expect(orchestrator_result.written).to be(true)
      expect(orchestrator_result.added).to include("anthropic/claude-opus-4-7", "anthropic/claude-sonnet-4-6")
      expect(orchestrator_result.updated["anthropic/claude-haiku-4-5"]).to include(
        "batch_input" => { "from" => nil, "to" => 0.5 }
      )

      written = JSON.parse(File.read(file.path))
      expect(written.dig("models", "anthropic/claude-opus-4-7", "input")).to eq(5.0)
      expect(written["models"]).not_to have_key("anthropic/claude-sonnet-3-7")
    end
  end

  it "does not write in dry_run mode" do
    Tempfile.create(["registry", ".json"]) do |file|
      original = JSON.pretty_generate(build_registry(haiku_entry: { "input" => 1.0, "output" => 5.0 }))
      file.write(original)
      file.close

      runs = described_class.new(io: io).call(
        providers: ["anthropic"],
        registry_path: file.path,
        dry_run: true
      )

      expect(runs.first.orchestrator.changed?).to be(true)
      expect(runs.first.orchestrator.written).to be(false)
      expect(File.read(file.path)).to eq(original)
    end
  end

  it "fetches all configured source pages for Groq" do
    stub_request(:get, LlmCostTracker::Pricing::Scrape::Providers::Groq.source_url)
      .to_return(status: 200, body: groq_models_html, headers: { "Content-Type" => "text/html; charset=utf-8" })
    stub_request(:get, LlmCostTracker::Pricing::Scrape::Providers::Groq::PROMPT_CACHING_SOURCE_URL)
      .to_return(status: 200, body: groq_prompt_caching_html,
                 headers: { "Content-Type" => "text/html; charset=utf-8" })
    stub_request(:get, LlmCostTracker::Pricing::Scrape::Providers::Groq::FLEX_PROCESSING_SOURCE_URL)
      .to_return(status: 200, body: groq_flex_processing_html,
                 headers: { "Content-Type" => "text/html; charset=utf-8" })
    stub_request(:get, LlmCostTracker::Pricing::Scrape::Providers::Groq::DEPRECATIONS_SOURCE_URL)
      .to_return(status: 200, body: groq_deprecations_html,
                 headers: { "Content-Type" => "text/html; charset=utf-8" })
    stub_request(:get, LlmCostTracker::Pricing::Scrape::Providers::Groq::BATCH_SOURCE_URL)
      .to_return(status: 200, body: groq_batch_html, headers: { "Content-Type" => "text/html; charset=utf-8" })
    stub_request(:get, LlmCostTracker::Pricing::Scrape::Providers::Groq::SPEECH_TO_TEXT_SOURCE_URL)
      .to_return(status: 200, body: File.read("spec/fixtures/scrape/groq_speech_to_text.html"),
                 headers: { "Content-Type" => "text/html; charset=utf-8" })

    Tempfile.create(["registry", ".json"]) do |file|
      file.write(JSON.pretty_generate("metadata" => { "schema_version" => 1, "updated_at" => "2026-04-01" },
                                      "models" => {}))
      file.close

      runs = described_class.new(io: io).call(providers: ["groq"], registry_path: file.path, dry_run: true)

      expect(runs.first.scraped.models).to include("openai/gpt-oss-20b")
      expect(runs.first.orchestrator.added).to include("groq/openai/gpt-oss-20b")
      expect(io.string).to include("[groq] fetching #{LlmCostTracker::Pricing::Scrape::Providers::Groq.source_url}")
      expect(io.string).to include(
        "[groq] fetching #{LlmCostTracker::Pricing::Scrape::Providers::Groq::PROMPT_CACHING_SOURCE_URL}"
      )
      expect(io.string).to include(
        "[groq] fetching #{LlmCostTracker::Pricing::Scrape::Providers::Groq::FLEX_PROCESSING_SOURCE_URL}"
      )
      expect(io.string).to include(
        "[groq] fetching #{LlmCostTracker::Pricing::Scrape::Providers::Groq::DEPRECATIONS_SOURCE_URL}"
      )
    end
  end

  it "fetches the pages a provider asks for after reading its sources, and keeps them out of source_urls" do
    provider = Class.new(LlmCostTracker::Pricing::Scrape::Providers::Base) do
      source_url "https://prices.example.test/"
      define_singleton_method(:followup_urls) { |pages| [pages.fetch(source_url).strip] }
      define_method(:call) do |html:, source_url:, scraped_at:|
        LlmCostTracker::Pricing::Scrape::Providers::Base::Result.new(
          source_url:, scraped_at:, deprecated_models: [], service_charges: {},
          models: { "model-a" => { "input" => Float(html.fetch("https://prices.example.test/a")) } }
        )
      end
    end
    stub_const("#{described_class}::PROVIDERS", "example" => provider)
    stub_request(:get, "https://prices.example.test/").to_return(status: 200, body: "https://prices.example.test/a\n")
    stub_request(:get, "https://prices.example.test/a").to_return(status: 200, body: "1.5")

    Tempfile.create(["registry", ".json"]) do |file|
      file.write(JSON.generate("metadata" => {}, "models" => {}))
      file.close

      runs = described_class.new(io: io).call(providers: %w[example], registry_path: file.path)

      expect(runs.first.scraped.models).to eq("model-a" => { "input" => 1.5 })
      expect(JSON.parse(File.read(file.path)).dig("metadata", "source_urls")).to eq(["https://prices.example.test/"])
    end
  end

  def litellm_provider(url, *more)
    Class.new(LlmCostTracker::Pricing::Scrape::Providers::Base) do
      const_set(:SOURCE_URLS, [url, LlmCostTracker::Pricing::Scrape::Providers::Litellm::SOURCE_URL, *more])
      source_url url
      define_method(:call) do |html:, source_url:, scraped_at:|
        input = Float(html.fetch(LlmCostTracker::Pricing::Scrape::Providers::Litellm::SOURCE_URL))
        LlmCostTracker::Pricing::Scrape::Providers::Base::Result.new(
          source_url:, scraped_at:, deprecated_models: [], service_charges: {}, models: { "model-a" => { "input" => input } }
        )
      end
    end
  end

  it "fetches each page once per run, and LiteLLM at the pinned commit under its canonical URL" do
    sha = "b" * 40
    stub_const("#{described_class}::PROVIDERS", "one" => litellm_provider("https://one.example.test/"),
                                                  "two" => litellm_provider("https://two.example.test/"))
    pinned = stub_request(:get, format(litellm::PRICES_URL, sha)).to_return(status: 200, body: "2.5")
    %w[one two].each { |name| stub_request(:get, "https://#{name}.example.test/").to_return(status: 200, body: "{}") }

    Tempfile.create(["registry", ".json"]) do |file|
      file.write(JSON.generate("metadata" => {}, "models" => {}))
      file.close

      runs = described_class.new(io: io, litellm_sha: sha).call(providers: %w[one two], registry_path: file.path)

      expect(runs.map { |run| run.scraped.models }).to all(eq("model-a" => { "input" => 2.5 }))
      expect(pinned).to have_been_requested.once
      expect(io.string).to include("[one] fetching #{format(litellm::PRICES_URL, sha)}")
      expect(JSON.parse(File.read(file.path)).dig("metadata", "source_urls"))
        .to eq(["https://one.example.test/", litellm::SOURCE_URL, "https://two.example.test/"])
    end
  end

  it "runs a provider without models.dev when it cannot be fetched, and fails on any other page" do
    stub_const("#{described_class}::PROVIDERS", "one" => litellm_provider("https://one.example.test/", litellm::MODELS_DEV_URL))
    stub_request(:get, litellm::SOURCE_URL).to_return(status: 200, body: "2.5")
    stub_request(:get, "https://one.example.test/").to_return(status: 200, body: "{}")
    stub_request(:get, litellm::MODELS_DEV_URL).to_return(status: 503)
    runner = described_class.new(io: io, fetcher: LlmCostTracker::Pricing::Scrape::Fetcher.new(sleep: ->(_) {}))

    Tempfile.create(["registry", ".json"]) do |file|
      file.write(JSON.generate("metadata" => {}, "models" => {}))
      file.close

      expect(runner.call(providers: %w[one], registry_path: file.path, dry_run: true).first.scraped.models)
        .to eq("model-a" => { "input" => 2.5 })
      expect(io.string).to include("[one] skipped #{litellm::MODELS_DEV_URL}")
      stub_request(:get, "https://one.example.test/").to_return(status: 503)
      expect { runner.call(providers: %w[one], registry_path: file.path, dry_run: true) }
        .to raise_error(described_class::Error, /failures: one/)
    end
  end

  it "fetches LiteLLM at main when no commit is pinned" do
    stub_const("#{described_class}::PROVIDERS", "one" => litellm_provider("https://one.example.test/"))
    main = stub_request(:get, litellm::SOURCE_URL).to_return(status: 200, body: "2.5")
    stub_request(:get, "https://one.example.test/").to_return(status: 200, body: "{}")

    Tempfile.create(["registry", ".json"]) do |file|
      file.write(JSON.generate("metadata" => {}, "models" => {}))
      file.close

      described_class.new(io: io).call(providers: %w[one], registry_path: file.path, dry_run: true)

      expect(main).to have_been_requested.once
    end
  end

  it "logs the final URL when a source page redirects elsewhere" do
    stub_request(:get, LlmCostTracker::Pricing::Scrape::Providers::Anthropic.source_url)
      .to_return(status: 301, headers: { "Location" => "https://example.test/moved" })
    stub_request(:get, "https://example.test/moved")
      .to_return(status: 200, body: html, headers: { "Content-Type" => "text/html; charset=utf-8" })

    Tempfile.create(["registry", ".json"]) do |file|
      file.write(JSON.pretty_generate(build_registry(haiku_entry: { "input" => 1.0, "output" => 5.0 })))
      file.close

      described_class.new(io: io).call(providers: ["anthropic"], registry_path: file.path, dry_run: true)

      expect(io.string).to include("[anthropic] redirected to https://example.test/moved")
    end
  end

  it "stays quiet about redirects when a source page answers directly" do
    Tempfile.create(["registry", ".json"]) do |file|
      file.write(JSON.pretty_generate(build_registry(haiku_entry: { "input" => 1.0, "output" => 5.0 })))
      file.close

      described_class.new(io: io).call(providers: ["anthropic"], registry_path: file.path, dry_run: true)

      expect(io.string).not_to include("redirected to")
    end
  end

  it "raises on an unknown provider name" do
    expect do
      described_class.new(io: io).call(providers: ["perplexity"])
    end.to raise_error(described_class::Error, /unknown providers/)
  end

  it "marks a provider run as failed and raises after the loop when its parser breaks" do
    stub_request(:get, LlmCostTracker::Pricing::Scrape::Providers::Anthropic.source_url)
      .to_return(status: 200, body: "<html><body></body></html>",
                 headers: { "Content-Type" => "text/html; charset=utf-8" })

    Tempfile.create(["registry", ".json"]) do |file|
      file.write(JSON.pretty_generate(build_registry(haiku_entry: { "input" => 1.0, "output" => 5.0 })))
      file.close

      expect do
        described_class.new(io: io).call(providers: ["anthropic"], registry_path: file.path)
      end.to raise_error(described_class::Error, /provider scrape failures: anthropic/)

      expect(io.string).to include("[anthropic] FAILED:")
      expect(io.string).to include("[summary] providers=1 ok=0 failed=1")
    end
  end

  it "dates nothing for a provider whose scrape failed" do
    stub_request(:get, LlmCostTracker::Pricing::Scrape::Providers::Anthropic.source_url)
      .to_return(status: 200, body: "<html><body></body></html>")

    Tempfile.create(["registry", ".json"]) do |file|
      original = JSON.generate(build_registry(haiku_entry: { "input" => 1.0, "output" => 5.0 }))
      file.write(original)
      file.close

      expect { described_class.new(io: io).call(providers: ["anthropic"], registry_path: file.path) }
        .to raise_error(described_class::Error)
      expect(File.read(file.path)).to eq(original)
    end
  end

  it "continues running remaining providers when one fails" do
    stub_request(:get, LlmCostTracker::Pricing::Scrape::Providers::Gemini.source_url)
      .to_return(status: 200, body: "<html><body></body></html>",
                 headers: { "Content-Type" => "text/html; charset=utf-8" })

    Tempfile.create(["registry", ".json"]) do |file|
      file.write(JSON.pretty_generate(build_registry(haiku_entry: { "input" => 1.0, "output" => 5.0 })))
      file.close

      expect do
        described_class.new(io: io).call(providers: %w[anthropic gemini], registry_path: file.path)
      end.to raise_error(described_class::Error, /provider scrape failures: gemini/)

      expect(io.string).to include("[anthropic] parsed")
      expect(io.string).to include("[gemini] FAILED:")
      expect(io.string).to include("[summary] providers=2 ok=1 failed=1")
    end
  end

  it "logs the notes a scraper returns and writes them for the cross-check" do
    result = LlmCostTracker::Pricing::Scrape::Providers::Base::Result
    provider = Class.new(LlmCostTracker::Pricing::Scrape::Providers::Base) do
      source_url "https://prices.example.test/"
      define_method(:call) do |source_url:, scraped_at:, **|
        result.new(source_url:, scraped_at:, models: {}, deprecated_models: [], service_charges: {},
                   notes: ["- `openai/gpt-7`: undecided"])
      end
    end
    stub_const("#{described_class}::PROVIDERS", "example" => provider,
               "gemini" => LlmCostTracker::Pricing::Scrape::Providers::Gemini)
    stub_request(:get, "https://prices.example.test/").to_return(status: 200, body: "{}")
    stub_request(:get, LlmCostTracker::Pricing::Scrape::Providers::Gemini.source_url)
      .to_return(status: 200, body: "<html><body></body></html>")
    stub_request(:get, LlmCostTracker::Pricing::Scrape::Providers::Gemini::VERTEX_URL)
      .to_return(status: 200, body: "<html><body></body></html>")

    Dir.mktmpdir do |dir|
      registry, notes = %w[prices.json notes.md].map { |name| File.join(dir, name) }
      File.write(registry, JSON.generate(build_registry(haiku_entry: { "input" => 1.0, "output" => 5.0 })))

      expect do
        described_class.new(io: io).call(providers: %w[example gemini], registry_path: registry, dry_run: true,
                                         notes_path: notes)
      end.to raise_error(described_class::Error, /failures: gemini/)

      expect(File.read(notes)).to eq("- `openai/gpt-7`: undecided\n")
      expect(io.string).to include("[example] - `openai/gpt-7`: undecided")
    end
  end

  it "logs the entries the orchestrator holds but leaves them out of the notes for the cross-check" do
    provider = Class.new(LlmCostTracker::Pricing::Scrape::Providers::Base) do
      source_url "https://prices.example.test/"
      define_method(:call) do |source_url:, scraped_at:, **|
        LlmCostTracker::Pricing::Scrape::Providers::Base::Result.new(
          source_url:, scraped_at:, deprecated_models: [], service_charges: {},
          models: { "gpt-4o-mini-tts" => { "input" => 0.6, "audio_output" => 12.0 } }
        )
      end
    end
    stub_const("#{described_class}::PROVIDERS", "openai" => provider)
    stub_request(:get, "https://prices.example.test/").to_return(status: 200, body: "{}")

    Dir.mktmpdir do |dir|
      registry, notes = %w[prices.json notes.md].map { |name| File.join(dir, name) }
      File.write(registry, JSON.generate(build_registry(haiku_entry: { "input" => 1.0, "output" => 5.0 })))

      described_class.new(io: io).call(providers: %w[openai], registry_path: registry, dry_run: true, notes_path: notes)

      held = "- `openai`: gpt-4o-mini-tts held until metadata.min_gem_version is 0.15.0"
      expect(File.read(notes)).to eq("")
      expect(io.string).to include("[openai] #{held}")
    end
  end
end
