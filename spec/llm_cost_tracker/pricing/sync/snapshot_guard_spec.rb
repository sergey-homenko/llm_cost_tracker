# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Pricing::Sync::SnapshotGuard do
  let(:current) do
    {
      "metadata" => { "currency" => "USD" },
      "models" => {
        "openai/gpt-4o" => { "input" => 2.5, "cache_read_input" => 1.25, "output" => 10.0 },
        "anthropic/claude-sonnet-4-5" => { "input" => 3.0, "output" => 15.0 },
        "gemini/gemini-2.5-pro" => { "input" => 1.25, "output" => 10.0 }
      },
      "service_charges" => { "anthropic" => { "web_search_request" => 10.0, "web_fetch_request" => 0.0 } }
    }
  end

  def findings(remote, from: current)
    changes = LlmCostTracker::Pricing::Sync.send(:registry_changes, from, remote)
    described_class.call(current: from, remote: remote, changes: changes)
  end

  it "accepts moves short of 100x, new or removed models, and dropped optional rates" do
    remote = current.deep_merge(
      "models" => {
        "openai/gpt-4o" => { "input" => 0.5 },
        "anthropic/claude-sonnet-4-5" => { "output" => 825.0 },
        "openai/gpt-6" => { "input" => 0.0, "output" => 1e30 }
      },
      "service_charges" => { "anthropic" => { "web_search_request" => 25.0 } }
    )
    remote["models"]["openai/gpt-4o"].delete("cache_read_input")
    remote["models"].delete("gemini/gemini-2.5-pro")

    expect(findings(remote)).to eq([])
  end

  it "flags zeroed or newly charged prices, removed input or output rates, and moves of 100x or more" do
    remote = current.deep_merge(
      "models" => { "openai/gpt-4o" => { "input" => 0 }, "anthropic/claude-sonnet-4-5" => { "input" => 0.02, "output" => 1500.0 } },
      "service_charges" => { "anthropic" => { "web_search_request" => 0.0, "web_fetch_request" => 10.0 } }
    )
    remote["models"]["openai/gpt-4o"].delete("output")

    expect(findings(remote)).to contain_exactly(
      "openai/gpt-4o input: 2.5 -> 0.0",
      "openai/gpt-4o output: 10.0 -> nil",
      "anthropic/claude-sonnet-4-5 input: 3.0 -> 0.02",
      "anthropic/claude-sonnet-4-5 output: 15.0 -> 1500.0",
      "anthropic.web_search_request: 10.0 -> 0.0",
      "anthropic.web_fetch_request: 0.0 -> 10.0"
    )
  end

  it "flags a currency switch, but nothing on a first refresh into an empty file" do
    remote = current.deep_merge("metadata" => { "currency" => "EUR" }, "models" => { "openai/gpt-4o" => { "input" => 0 } })

    expect(findings(remote)).to contain_exactly("openai/gpt-4o input: 2.5 -> 0.0", "currency: USD -> EUR")
    expect(findings(remote, from: {})).to eq([])
  end
end
