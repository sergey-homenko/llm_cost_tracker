# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe LlmCostTracker::Pricing::Sync::RegistryWriter do
  let(:writer) { described_class.new }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  def path_for(name)
    File.join(@tmpdir, name)
  end

  it "writes the registry to a JSON file when the path ends with .json" do
    path = path_for("prices.json")
    writer.call(path: path, registry: { "models" => { "openai/gpt-x" => { "input" => 1.0 } } })

    expect(JSON.parse(File.read(path))).to eq("models" => { "openai/gpt-x" => { "input" => 1.0 } })
  end

  it "preserves manually curated entries when the remote refresh runs" do
    path = path_for("prices.json")
    File.write(path, JSON.pretty_generate(
                       "models" => {
                         "openai/local-experiment" => { "input" => 5.0, "_source" => "manual" },
                         "openai/gpt-x" => { "input" => 1.0, "_source" => "remote" }
                       }
                     ))

    writer.call(
      path: path,
      registry: {
        "models" => {
          "openai/gpt-x" => { "input" => 2.0, "_source" => "remote" }
        }
      }
    )

    written = JSON.parse(File.read(path))
    expect(written["models"]).to eq(
      "openai/gpt-x" => { "input" => 2.0, "_source" => "remote" },
      "openai/local-experiment" => { "input" => 5.0, "_source" => "manual" }
    )
  end

  it "ignores manual entries that are missing the _source marker" do
    path = path_for("prices.json")
    File.write(path, JSON.pretty_generate("models" => { "openai/legacy" => { "input" => 9.0 } }))

    writer.call(
      path: path,
      registry: { "models" => { "openai/gpt-x" => { "input" => 2.0 } } }
    )

    expect(JSON.parse(File.read(path))["models"]).to eq("openai/gpt-x" => { "input" => 2.0 })
  end

  it "writes hash keys sorted alphabetically at every level" do
    path = path_for("prices.json")
    writer.call(
      path: path,
      registry: {
        "models" => {
          "openai/gpt-x" => { "output" => 2.0, "input" => 1.0, "cache_read_input" => 0.5 },
          "anthropic/claude-z" => { "output" => 5.0, "input" => 3.0 }
        },
        "service_charges" => {
          "openai" => { "web_search_request" => 10.0, "file_search_call" => 2.5 },
          "anthropic" => { "web_search_request" => 10.0, "code_execution_hour" => 0.05 }
        },
        "metadata" => { "updated_at" => "2026-05-13", "currency" => "USD", "schema_version" => 1 }
      }
    )

    written = JSON.parse(File.read(path))
    expect(written.keys).to eq(%w[metadata models service_charges])
    expect(written["metadata"].keys).to eq(%w[currency schema_version updated_at])
    expect(written["models"].keys).to eq(%w[anthropic/claude-z openai/gpt-x])
    expect(written.dig("models", "openai/gpt-x").keys).to eq(%w[cache_read_input input output])
    expect(written["service_charges"].keys).to eq(%w[anthropic openai])
    expect(written.dig("service_charges", "anthropic").keys).to eq(%w[code_execution_hour web_search_request])
  end

  it "preserves array element order while sorting hash keys inside" do
    path = path_for("prices.json")
    writer.call(
      path: path,
      registry: {
        "metadata" => {
          "source_urls" => ["https://b.example", "https://a.example", "https://c.example"]
        },
        "models" => { "openai/x" => { "output" => 1.0, "input" => 0.5 } }
      }
    )

    written = JSON.parse(File.read(path))
    expect(written.dig("metadata", "source_urls")).to eq(
      ["https://b.example", "https://a.example", "https://c.example"]
    )
  end

  it "preserves service_charges for providers absent from the registry, replaces per-provider when present" do
    path = path_for("prices.json")
    File.write(path, JSON.pretty_generate(
                       "service_charges" => {
                         "anthropic" => { "web_search_request" => 10.0, "code_execution_hour" => 0.05 },
                         "openai" => { "web_search_request" => 8.0, "stale_legacy" => 99.0 }
                       }
                     ))

    writer.call(
      path: path,
      registry: { "service_charges" => { "openai" => { "web_search_request" => 10.0 } } }
    )

    written = JSON.parse(File.read(path))
    expect(written["service_charges"]).to eq(
      "anthropic" => { "web_search_request" => 10.0, "code_execution_hour" => 0.05 },
      "openai" => { "web_search_request" => 10.0 }
    )
  end
end
