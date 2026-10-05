# frozen_string_literal: true

require "spec_helper"
require "price_scrape/providers/gemini"

RSpec.describe LlmCostTracker::Pricing::Scrape::Providers::Gemini do
  let(:fixture_path) { File.expand_path("../../../fixtures/scrape/gemini_pricing.html", __dir__) }
  let(:html) { File.read(fixture_path, encoding: "utf-8") }

  describe "#call" do
    it "extracts standard and batch text input/output rates for current models" do
      result = described_class.new.call(html: html, scraped_at: "2026-09-26T00:00:00Z")

      expect(result.source_url).to eq(described_class.source_url)
      expect(result.scraped_at).to eq("2026-09-26T00:00:00Z")
      expect(result.models.fetch("gemini-2.5-pro")).to eq(
        "grounding_request" => 35.0,
        "maps_grounding_request" => 25.0,
        "cache_storage_token_hour" => 4.5,
        "input" => 1.25,
        "output" => 10.0,
        "image_input" => 1.25,
        "audio_input" => 1.25,
        "cache_read_input" => 0.125,
        "batch_input" => 0.625,
        "batch_output" => 5.0,
        "batch_image_input" => 0.625,
        "batch_audio_input" => 0.625,
        "batch_cache_read_input" => 0.125,
        "_context_price_threshold_tokens" => 200_000,
        "above_context_input" => 2.5,
        "above_context_output" => 15.0,
        "above_context_image_input" => 2.5,
        "above_context_audio_input" => 2.5,
        "above_context_cache_read_input" => 0.25,
        "above_context_batch_input" => 1.25,
        "above_context_batch_output" => 7.5,
        "above_context_batch_image_input" => 1.25,
        "above_context_batch_audio_input" => 1.25,
        "above_context_batch_cache_read_input" => 0.25,
        "flex_input" => 0.625,
        "flex_output" => 5.0,
        "flex_image_input" => 0.625,
        "flex_audio_input" => 0.625,
        "flex_cache_read_input" => 0.125,
        "above_context_flex_input" => 1.25,
        "above_context_flex_output" => 7.5,
        "above_context_flex_image_input" => 1.25,
        "above_context_flex_audio_input" => 1.25,
        "above_context_flex_cache_read_input" => 0.25,
        "priority_input" => 2.25,
        "priority_output" => 18.0,
        "priority_image_input" => 2.25,
        "priority_audio_input" => 2.25,
        "priority_cache_read_input" => 0.225,
        "above_context_priority_input" => 4.5,
        "above_context_priority_output" => 27.0,
        "above_context_priority_image_input" => 4.5,
        "above_context_priority_audio_input" => 4.5,
        "above_context_priority_cache_read_input" => 0.45
      )
      expect(result.models.fetch("gemini-2.5-flash")).to eq(
        "grounding_request" => 35.0,
        "maps_grounding_request" => 25.0,
        "cache_storage_token_hour" => 1.0,
        "input" => 0.30,
        "output" => 2.50,
        "image_input" => 0.30,
        "audio_input" => 1.0,
        "cache_read_input" => 0.03,
        "audio_cache_read_input" => 0.1,
        "batch_input" => 0.15,
        "batch_output" => 1.25,
        "batch_image_input" => 0.15,
        "batch_audio_input" => 0.5,
        "batch_cache_read_input" => 0.03,
        "batch_audio_cache_read_input" => 0.1,
        "flex_input" => 0.15,
        "flex_output" => 1.25,
        "flex_image_input" => 0.15,
        "flex_audio_input" => 0.5,
        "flex_cache_read_input" => 0.03,
        "flex_audio_cache_read_input" => 0.1,
        "priority_input" => 0.54,
        "priority_output" => 4.5,
        "priority_image_input" => 0.54,
        "priority_audio_input" => 1.8,
        "priority_cache_read_input" => 0.054,
        "priority_audio_cache_read_input" => 0.18
      )
      expect(result.models.fetch("gemini-2.5-flash-lite")).to include(
        "audio_input" => 0.30,
        "batch_audio_input" => 0.15,
        "flex_audio_input" => 0.15,
        "priority_audio_input" => 0.54
      )
      expect(result.models.fetch("gemini-3.1-flash-lite")).to eq(
        "grounding_request" => 14.0,
        "maps_grounding_request" => 14.0,
        "cache_storage_token_hour" => 1.0,
        "input" => 0.25,
        "output" => 1.5,
        "image_input" => 0.25,
        "audio_input" => 0.5,
        "cache_read_input" => 0.025,
        "audio_cache_read_input" => 0.05,
        "batch_input" => 0.125,
        "batch_output" => 0.75,
        "batch_image_input" => 0.125,
        "batch_audio_input" => 0.25,
        "batch_cache_read_input" => 0.0125,
        "batch_audio_cache_read_input" => 0.025,
        "flex_input" => 0.125,
        "flex_output" => 0.75,
        "flex_image_input" => 0.125,
        "flex_audio_input" => 0.25,
        "flex_cache_read_input" => 0.0125,
        "flex_audio_cache_read_input" => 0.025,
        "priority_input" => 0.45,
        "priority_output" => 2.7,
        "priority_image_input" => 0.45,
        "priority_audio_input" => 0.9,
        "priority_cache_read_input" => 0.045,
        "priority_audio_cache_read_input" => 0.09
      )
    end

    it "returns at least the minimum expected number of models" do
      result = described_class.new.call(html: html)
      expect(result.models.size).to be >= described_class.min_models
    end

    it "sets deprecated_models to empty" do
      result = described_class.new.call(html: html)
      expect(result.deprecated_models).to eq([])
    end

    it "includes preview models alongside stable text models so dated/preview snapshots get priced" do
      result = described_class.new.call(html: html)

      preview_ids = result.models.keys.select { |id| id.include?("-preview") }
      expect(preview_ids).not_to be_empty
    end

    it "prices image models' text and image tokens separately, per 1M tokens" do
      models = described_class.new.call(html: html).models

      expect(models.fetch("gemini-3-pro-image")).to eq(
        "grounding_request" => 14.0,
        "input" => 2.0,
        "output" => 12.0,
        "image_input" => 2.0,
        "image_output" => 120.0,
        "batch_input" => 1.0,
        "batch_output" => 6.0,
        "batch_image_input" => 1.0,
        "batch_image_output" => 60.0,
        "flex_input" => 1.0,
        "flex_output" => 6.0,
        "flex_image_input" => 1.0,
        "flex_image_output" => 60.0,
        "priority_input" => 3.6,
        "priority_output" => 21.6,
        "priority_image_input" => 3.6,
        "priority_image_output" => 216.0
      )
      expect(models.fetch("gemini-2.5-flash-image")).to eq(
        "input" => 0.3,
        "output" => 2.5,
        "image_input" => 0.3,
        "image_output" => 30.0,
        "batch_input" => 0.15,
        "batch_output" => 1.25,
        "batch_image_input" => 0.15,
        "batch_image_output" => 15.0,
        "flex_input" => 0.15,
        "flex_output" => 1.25,
        "flex_image_input" => 0.15,
        "flex_image_output" => 15.0,
        "priority_input" => 0.54,
        "priority_output" => 4.5,
        "priority_image_input" => 0.54,
        "priority_image_output" => 54.0
      )
    end

    it "raises when an image model's text is priced as a model the page does not price" do
      broken_html = html.sub('priced the same as
<a href="#gemini-2.5-flash">', 'priced the same as
<a href="#gemini-2.4-flash">')

      expect do
        described_class.new.call(html: broken_html)
      end.to raise_error(described_class::Error, /gemini-2.5-flash-image text is priced as "gemini-2.4-flash"/)
    end

    it "raises when a per-image output price has no per-token rate footnote" do
      broken_html = html.sub("[*] Image output is priced at $30", "[*] Image output is priced at thirty dollars")
      expect do
        described_class.new.call(html: broken_html)
      end.to raise_error(described_class::Error, /image output rate not found/)
    end

    it "raises when the pricing article body is missing" do
      expect do
        described_class.new.call(html: "<html><body></body></html>")
      end.to raise_error(described_class::Error, /article body not found/)
    end

    it "raises when standard pricing tables are missing" do
      tableless_html = html.gsub(%r{<table\b.*?</table>}m, "")

      expect do
        described_class.new.call(html: tableless_html)
      end.to raise_error(described_class::Error, /at least \d+ models/)
    end

    it "raises when the parsed model count is below the minimum" do
      sparse_html = <<~HTML
        <html><body>
          <div class="devsite-article-body clearfix">
            <div class="models-section">
              <div class="heading-group">
                <h2>Gemini 2.5 Pro</h2>
                <em><code>gemini-2.5-pro</code></em>
              </div>
            </div>
            <div class="ds-selector-tabs">
              <section>
                <h3>Standard</h3>
                <table>
                  <thead>
                    <tr><th></th><th>Free Tier</th><th>Paid Tier, per 1M tokens in USD</th></tr>
                  </thead>
                  <tbody>
                    <tr><td>Input price</td><td>Free</td><td>$1.25, prompts &lt;= 200k tokens</td></tr>
                    <tr><td>Output price</td><td>Free</td><td>$10.00, prompts &lt;= 200k tokens</td></tr>
                  </tbody>
                </table>
              </section>
              <section>
                <h3>Batch</h3>
                <table>
                  <thead>
                    <tr><th></th><th>Free Tier</th><th>Paid Tier, per 1M tokens in USD</th></tr>
                  </thead>
                  <tbody>
                    <tr><td>Input price</td><td>Not available</td><td>$0.625, prompts &lt;= 200k tokens</td></tr>
                    <tr><td>Output price</td><td>Not available</td><td>$5.00, prompts &lt;= 200k tokens</td></tr>
                  </tbody>
                </table>
              </section>
            </div>
          </div>
        </body></html>
      HTML

      expect do
        described_class.new.call(html: sparse_html)
      end.to raise_error(described_class::Error, /at least \d+ models/)
    end

    it "raises when a price cell does not match the expected format" do
      broken_html = html.sub("<td>$0.10 (text / image / video)<br>$0.30 (audio)</td>", "<td>TBD</td>")
      expect do
        described_class.new.call(html: broken_html)
      end.to raise_error(described_class::Error, /unable to parse price/)
    end

    it "raises when a batch price cell does not match the expected format" do
      broken_html = html.sub("<td>$0.05 (text / image / video)<br>$0.15 (audio)</td>", "<td>TBD</td>")
      expect do
        described_class.new.call(html: broken_html)
      end.to raise_error(described_class::Error, /unable to parse price/)
    end
  end
  it "prices Google Search grounding per model family, including web and image search on image models" do
    models = described_class.new.call(html: html, scraped_at: "2026-09-26T00:00:00Z").models

    expect(models.fetch("gemini-2.5-pro")["grounding_request"]).to eq(35.0)
    expect(models.fetch("gemini-3-flash-preview")["grounding_request"]).to eq(14.0)
    expect(models.fetch("gemini-3.1-flash-image")["grounding_request"]).to eq(14.0)
  end

  it "prices Google Maps grounding and explicit cache storage from the Standard table" do
    models = described_class.new.call(html: html, scraped_at: "2026-09-26T00:00:00Z").models

    expect(models.fetch("gemini-2.5-flash-lite")).to include("maps_grounding_request" => 25.0,
                                                             "cache_storage_token_hour" => 1.0)
    expect(models.fetch("gemini-3.1-pro-preview")).to include("maps_grounding_request" => 14.0,
                                                              "cache_storage_token_hour" => 4.5)
    expect(models.fetch("gemini-3.1-flash-image")).not_to include("maps_grounding_request", "cache_storage_token_hour")
  end

  it "prices every model id in a section heading, including text-to-speech models" do
    models = described_class.new.call(html: html, scraped_at: "2026-09-26T00:00:00Z").models

    expect(models.fetch("gemini-3.1-pro-preview-customtools")).to eq(models.fetch("gemini-3.1-pro-preview"))
    expect(models.fetch("gemini-3.8-flash-tts")).to include("input" => 0.5, "audio_output" => 9.0,
                                                            "batch_input" => 0.25, "batch_audio_output" => 4.5)
    expect(models.fetch("gemini-2.5-flash-preview-tts")).to include("input" => 0.5, "audio_output" => 10.0)
    expect(models.keys.grep(/-live|streaming|native-audio/)).to eq(["gemini-3.5-transcribe-live"])
  end

  it "prices models published without a Batch tier or pricing tabs" do
    models = described_class.new.call(html: html, scraped_at: "2026-09-26T00:00:00Z").models

    expect(models.fetch("gemini-omni-1.1-flash")).to eq(
      "input" => 1.5, "image_input" => 1.5, "audio_input" => 1.5, "output" => 9.0, "video_output" => 17.5
    )
    expect(models.fetch("gemini-3.5-transcribe")).to include("audio_input" => 2.0, "output" => 12.0)
    expect(models.fetch("gemini-3.5-transcribe-live")).to include("audio_input" => 3.5, "output" => 21.0)
  end

  it "reads the long-context threshold from the prompt tier rows" do
    models = described_class.new.call(html: html.gsub("200k", "128k"), scraped_at: "2026-09-26T00:00:00Z").models

    expect(models.fetch("gemini-2.5-pro")).to include(
      "_context_price_threshold_tokens" => 128_000, "above_context_input" => 2.5, "above_context_cache_read_input" => 0.25
    )
  end

  it "raises when a prompt tier row names no size or another size than the model's other tiers" do
    input_row = "$1.25, prompts <= 200k tokens<br>$2.50, prompts > 200k tokens"
    cache_row = "$0.125, prompts <= 200k tokens<br>$0.25, prompts > 200k<br>"

    expect { described_class.new.call(html: html.sub(input_row, input_row.sub("> 200k", "> 200,000"))) }
      .to raise_error(described_class::Error, /prompt tier size not found/)
    expect { described_class.new.call(html: html.sub(input_row, input_row.sub("> 200k", "> 128k"))) }
      .to raise_error(described_class::Error, /input and output prompt tiers split at different sizes/)
    expect { described_class.new.call(html: html.sub(cache_row, cache_row.sub("> 200k", "> 128k"))) }
      .to raise_error(described_class::Error, /context caching prompt tier splits at a different size/)
  end

  it "prices newly scraped models at their published rates" do
    models = described_class.new.call(html: html, scraped_at: "2026-09-26T00:00:00Z").models
    scraped = %w[gemini-3.1-pro-preview-customtools gemini-3.8-flash-tts gemini-2.5-flash-preview-tts gemini-embedding-2]
    LlmCostTracker.configure do |config|
      config.pricing.overrides = models.slice(*scraped).transform_keys { |id| "gemini/#{id}" }
    end
    cost = ->(model, tokens) { LlmCostTracker::Pricing.cost_for(provider: "gemini", model: model, tokens: tokens).total }

    expect(cost.call("gemini-3.1-pro-preview-customtools", input_tokens: 10_000, output_tokens: 1_000)).to eq(BigDecimal("0.032"))
    expect(cost.call("gemini-3.8-flash-tts", input_tokens: 20, audio_output_tokens: 250)).to eq(BigDecimal("0.00226"))
    expect(cost.call("gemini-2.5-flash-preview-tts", input_tokens: 20, audio_output_tokens: 250)).to eq(BigDecimal("0.00251"))
    expect(cost.call("gemini-embedding-2", input_tokens: 500)).to eq(BigDecimal("0.0001"))
  end

  it "prices Gemini Embedding 2 input by modality" do
    models = described_class.new.call(html: html, scraped_at: "2026-09-26T00:00:00Z").models

    expect(models.fetch("gemini-embedding-2")).to eq(
      "input" => 0.2, "image_input" => 0.45, "audio_input" => 6.5, "video_input" => 12.0,
      "batch_input" => 0.1, "batch_image_input" => 0.225, "batch_audio_input" => 3.25, "batch_video_input" => 6.0
    )
  end

  it "keeps an announced price change under a dated key until the date, then as the price itself" do
    before_change = described_class.new.call(html: html, scraped_at: "2026-09-26T00:00:00Z").models
    after_change = described_class.new.call(html: html, scraped_at: "2027-01-01T08:00:00Z").models

    expect(before_change.fetch("gemini-3.8-flash")).to include(
      "input" => 0.75, "input_from_2027-01-01" => 1.5,
      "output" => 3.75, "output_from_2027-01-01" => 7.5,
      "batch_input" => 0.375, "batch_input_from_2027-01-01" => 0.75,
      "cache_read_input" => 0.075, "cache_read_input_from_2027-01-01" => 0.15,
      "cache_storage_token_hour" => 0.5, "cache_storage_token_hour_from_2027-01-01" => 1.0,
      "grounding_request" => 14.0
    )
    expect(before_change.fetch("gemini-3.8-flash")).not_to include("grounding_request_from_2027-01-01")
    expect(before_change.fetch("gemini-3.8-flash-tts")).to include("audio_output_from_2027-01-01" => 18.0)
    expect(after_change.fetch("gemini-3.8-flash")).to include("input" => 1.5, "output" => 7.5,
                                                              "cache_storage_token_hour" => 1.0)
    expect(after_change.fetch("gemini-3.8-flash").keys.grep(/_from_/)).to be_empty
    expect(after_change.fetch("gemini-2.5-flash")).to eq(before_change.fetch("gemini-2.5-flash"))
  end
end
