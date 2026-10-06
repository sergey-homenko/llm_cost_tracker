# frozen_string_literal: true

require "spec_helper"
require "json"
require "price_scrape/providers/cohere"

RSpec.describe LlmCostTracker::Pricing::Scrape::Providers::Cohere do
  let(:litellm) { LlmCostTracker::Pricing::Scrape::Providers::Litellm }
  let(:pricing) { fixture("cohere_pricing.html") }
  let(:overview) { fixture("cohere_models.md") }
  let(:catalogue) do
    chat = ->(input, output) { { "litellm_provider" => "cohere_chat", "mode" => "chat",
                                 "input_cost_per_token" => input, "output_cost_per_token" => output } }
    embedding = { "litellm_provider" => "cohere", "mode" => "embedding", "input_cost_per_token" => 1.2e-07 }
    {
      "command-a-03-2025" => chat.call(2.5e-06, 1e-05), "command-r-08-2024" => chat.call(2e-07, 6e-07),
      "command-a-plus-05-2026" => chat.call(2.5e-06, 1e-05), "cohere/embed-v5.0-pro" => embedding,
      "embed-v4.0" => embedding,
      "rerank-v3.5" => { "litellm_provider" => "cohere", "mode" => "rerank", "input_cost_per_query" => 0.002 }
    }
  end
  let(:models_dev) do
    { "cohere" => { "models" => {
      "command-a-03-2025" => { "cost" => { "input" => 2.5, "output" => 10 } },
      "command-r-08-2024" => { "cost" => { "input" => 0.2, "output" => 0.6 } },
      "command-a-plus-05-2026" => { "cost" => { "input" => 2.5, "output" => 10 } }
    } } }
  end
  let(:pages) do
    { described_class.source_url => pricing, described_class::MODELS_SOURCE_URL => overview,
      litellm::SOURCE_URL => JSON.generate(catalogue), litellm::MODELS_DEV_URL => JSON.generate(models_dev) }
  end

  def fixture(name) = File.read("spec/fixtures/scrape/#{name}", encoding: "utf-8")

  def scrape(page = pricing, listed = overview, sources: pages)
    sources = sources.merge(described_class.source_url => page, described_class::MODELS_SOURCE_URL => listed)
    described_class.new.call(html: sources, scraped_at: "2026-10-06T06:00:00Z")
  end

  it "reads every priced card and FAQ price under the API id its models overview gives, retired ones left out" do
    result = scrape

    expect(result.models.except("command-a-03-2025")).to eq(
      "command-r-08-2024" => { "input" => 0.15, "output" => 0.6 },
      "command-r7b-12-2024" => { "input" => 0.0375, "output" => 0.15 },
      "embed-v5.0-pro" => { "input" => 0.12 }, "embed-v5.0-fast" => { "input" => 0.08 },
      "rerank-v4.0-fast" => { "rerank_search_unit" => 2.0 }, "rerank-v4.0-pro" => { "rerank_search_unit" => 2.5 },
      "parse-v5.0" => { "ocr_page" => 1.5 },
      "command" => { "input" => 1.0, "output" => 2.0 }, "command-light" => { "input" => 0.3, "output" => 0.6 },
      "command-r-03-2024" => { "input" => 0.5, "output" => 1.5 },
      "command-r-plus-04-2024" => { "input" => 3.0, "output" => 15.0 },
      "command-r-plus-08-2024" => { "input" => 2.5, "output" => 10.0 },
      "c4ai-aya-expanse-32b" => { "input" => 0.5, "output" => 1.5 }
    )
    expect(result.deprecated_models).to contain_exactly("c4ai-aya-expanse-8b", "c4ai-aya-vision-8b")
  end

  it "keeps official prices whole and adds LiteLLM rows models.dev confirms only for models the page does not price" do
    result = scrape

    expect(result.models.fetch("command-a-03-2025")).to eq("input" => 2.5, "output" => 10.0, "_source" => "litellm")
    expect(result.models.fetch("command-r-08-2024")).to eq("input" => 0.15, "output" => 0.6)
    expect(result.models).not_to include("command-a-plus-05-2026", "north-mini-code-1-0", "embed-v4.0", "rerank-v3.5")
    expect(result.notes).to be_empty
  end

  it "writes official rows but no LiteLLM row, and notes it, when models.dev is unreachable" do
    result = scrape(sources: pages.except(litellm::MODELS_DEV_URL))

    expect(result.models).to include("embed-v5.0-pro")
    expect(result.models).not_to include("command-a-03-2025")
    expect(result.notes).to eq(["- `cohere`: models.dev was unreachable or invalid, so no LiteLLM-only row was written"])
  end

  it "reads the pricing sections past a text row with multibyte characters" do
    page = pricing.sub('\n38:[', '\n9:T6,héllo38:[')

    expect(scrape(page).models).to include("c4ai-aya-expanse-32b")
  end

  it "raises when the price cards, the FAQ or the models overview tables are missing" do
    expect { scrape(pricing.gsub("web3PricingSection", "web3PromoSection")) }
      .to raise_error(described_class::Error, /web3PricingSection not found/)
    expect { scrape(pricing.gsub("web3AccordionSection", "web3PromoSection")) }
      .to raise_error(described_class::Error, /web3AccordionSection not found/)
    expect { scrape(pricing, overview.gsub("| Model Name", "| Model")) }
      .to raise_error(described_class::Error, /lists no API ids/)
  end

  it "raises on a unit, label, free offer, FAQ wording or model status it does not know" do
    expect { scrape(pricing.sub("1K searches", "1K queries")) }
      .to raise_error(described_class::Error, /Rerank 4 Fast price 2 per 1K queries \(Cost\) not understood/)
    expect { scrape(pricing.sub('\"inputLabel\":\"Input\",\"inputPrice\":0.15', '\"inputLabel\":\"Batch\",\"inputPrice\":0.15')) }
      .to raise_error(described_class::Error, /Command R price 0.15 per 1M tokens \(Batch\) not understood/)
    expect { scrape(pricing.sub('\"inputLabel\":\"API key\",\"inputPrice\":0', '\"inputLabel\":\"API key\",\"inputPrice\":1')) }
      .to raise_error(described_class::Error, /Command A\+ price 1 per Free \(API key\) not understood/)
    expect { scrape(pricing.sub("Command R+ 04-2024 pricing is", "Command R+ 04-2024 costs")) }
      .to raise_error(described_class::Error, /FAQ price not understood: Command R\+ 04-2024 costs/)
    expect { scrape(pricing, overview.sub("Retired Apr 4, 2026", "Sunset Apr 4, 2026")) }
      .to raise_error(described_class::Error, /status "Sunset Apr 4, 2026" not understood/)
  end

  it "raises when a card matches no API id or several without one live, a FAQ name several, or two names one id" do
    expect { scrape(pricing.sub("Embed 5 Pro", "Embed 6 Pro")) }
      .to raise_error(described_class::Error, /for "Embed 6 Pro": \[\]/)
    deprecated = overview.sub("| `command-r-08-2024`           | Live                     |",
                              "| `command-r-08-2024`           | Deprecated Sept 15, 2025 |")
    expect { scrape(pricing, deprecated) }
      .to raise_error(described_class::Error, /for "Command R": \["command-r-08-2024", "command-r-03-2024", "command-r"\]/)
    undated = pricing.sub("Command R+ 04-2024 pricing is", "Command R+ pricing is")
                     .sub("Command R+ 08-2024 pricing is $2.50/1M tokens for input and $10.00/1M tokens for output", "")
    expect { scrape(undated) }
      .to raise_error(described_class::Error, /for "Command R\+": \["command-r-plus-08-2024", "command-r-plus-04-2024", "command-r-plus"\]/)
    expect { scrape(pricing.sub("Command R7B", "Command R+")) }
      .to raise_error(described_class::Error, /prices command-r-plus-08-2024 twice/)
  end
end
