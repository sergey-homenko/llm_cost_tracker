# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Pricing::Sync::SnapshotGuard do
  let(:current) do
    {
      "metadata" => { "currency" => "USD" },
      "models" => {
        "openai/gpt-4o" => { "input" => 2.5, "cache_read_input" => 1.25, "output" => 10.0 },
        "anthropic/claude-sonnet-4-5" => { "input" => 3.0, "output" => 15.0 },
        "gemini/gemini-2.5-pro" => {
          "_context_price_threshold_tokens" => 200_000,
          "input" => 1.25,
          "output" => 10.0,
          "above_context_input" => 2.5
        },
        "openrouter/deepseek/deepseek-v4-pro" => { "input" => 0.4, "cache_read_input" => 0.003625, "output" => 1.6 }
      },
      "service_charges" => { "anthropic" => { "web_search_request" => 10.0, "web_fetch_request" => 0.0 } }
    }
  end

  def findings(remote, from: current)
    changes = LlmCostTracker::Pricing::Sync.send(:registry_changes, from, remote)
    described_class.call(current: from, remote: remote, changes: changes)
  end

  def remote_with(models: {}, service_charges: {}, metadata: {})
    current.deep_merge(
      "metadata" => metadata,
      "models" => models,
      "service_charges" => service_charges
    )
  end

  describe ".call" do
    it "accepts price moves the bundled price history has seen, new models, and dropped optional rates" do
      remote = remote_with(
        models: {
          "openai/gpt-4o" => { "input" => 0.5 },
          "anthropic/claude-sonnet-4-5" => { "output" => 30.0 },
          "gemini/gemini-2.5-pro" => { "_context_price_threshold_tokens" => 1 },
          "openrouter/deepseek/deepseek-v4-pro" => { "cache_read_input" => 0.135 },
          "openai/gpt-6" => { "input" => 0.0, "output" => 1e30 }
        },
        service_charges: { "anthropic" => { "web_search_request" => 25.0 } }
      )
      remote["models"]["openai/gpt-4o"].delete("cache_read_input")
      remote["models"]["gemini/gemini-2.5-pro"].delete("above_context_input")

      expect(findings(remote)).to eq([])
    end

    it "flags prices set to zero, removed input or output rates, and moves of 100x or more" do
      remote = remote_with(
        models: {
          "openai/gpt-4o" => { "input" => 0 },
          "anthropic/claude-sonnet-4-5" => { "input" => 0.03, "output" => 1e30 },
          "openrouter/deepseek/deepseek-v4-pro" => { "output" => 160.0 }
        }
      )
      remote["models"]["openai/gpt-4o"].delete("output")

      expect(findings(remote)).to contain_exactly(
        "openai/gpt-4o input: 2.5 -> 0.0 (set to zero)",
        "openai/gpt-4o output: 10.0 -> nil (removed)",
        "anthropic/claude-sonnet-4-5 input: 3.0 -> 0.03 (down 100x or more)",
        "anthropic/claude-sonnet-4-5 output: 15.0 -> 1.0e+30 (up 100x or more)",
        "openrouter/deepseek/deepseek-v4-pro output: 1.6 -> 160.0 (up 100x or more)"
      )
    end

    it "flags a model entry emptied of its prices, which would shadow the bundled rates" do
      remote = remote_with
      remote["models"]["anthropic/claude-sonnet-4-5"] = {}

      expect(findings(remote)).to contain_exactly(
        "anthropic/claude-sonnet-4-5 input: 3.0 -> nil (removed)",
        "anthropic/claude-sonnet-4-5 output: 15.0 -> nil (removed)"
      )
    end

    it "flags service charges set to zero or charged after being free" do
      remote = remote_with(
        service_charges: { "anthropic" => { "web_search_request" => 0.0, "web_fetch_request" => 10.0 } }
      )

      expect(findings(remote)).to contain_exactly(
        "anthropic.web_search_request: 10.0 -> 0.0 (set to zero)",
        "anthropic.web_fetch_request: 0.0 -> 10.0 (was zero)"
      )
    end

    it "flags a snapshot that drops more than a third of the models, not counting manual entries" do
      local = current.deep_merge("models" => { "acme/finetune" => { "input" => 1.0, "_source" => "manual" } })
      one_dropped = current.merge("models" => current["models"].except("gemini/gemini-2.5-pro"))
      two_dropped = current.merge("models" => current["models"].except("gemini/gemini-2.5-pro", "openai/gpt-4o"))

      expect(findings(one_dropped, from: local)).to eq([])
      expect(findings(two_dropped, from: local)).to eq(["2 of 4 models removed"])
    end

    it "flags a currency switch against an existing price table but not on a first refresh" do
      remote = remote_with(metadata: { "currency" => "EUR" })

      expect(findings(remote)).to eq(["currency: USD -> EUR"])
      expect(findings(remote, from: {})).to eq([])
      expect(findings(remote_with(metadata: { "currency" => "usd" }), from: current.except("metadata"))).to eq([])
    end

    it "has nothing to compare on a first refresh into an empty file" do
      remote = remote_with(models: { "openai/gpt-4o" => { "input" => 0, "output" => 1e30 } })

      expect(findings(remote, from: {})).to eq([])
      expect(findings(remote, from: { "metadata" => {}, "models" => nil })).to eq([])
    end
  end
end
