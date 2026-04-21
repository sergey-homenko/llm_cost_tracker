# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker do
  describe ".track_stream" do
    let(:events) do
      captured = []
      ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
        captured << payload
      end
      captured
    end

    it "parses OpenAI-shaped chunks via the matching provider parser" do
      collected = events

      described_class.track_stream(provider: "openai", model: "gpt-4o") do |stream|
        stream.event({ "model" => "gpt-4o", "choices" => [{ "delta" => { "content" => "hi" } }] })
        stream.event({ "usage" => { "prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15 } })
      end

      expect(collected.size).to eq(1)
      expect(collected.first[:provider]).to eq("openai")
      expect(collected.first[:input_tokens]).to eq(12)
      expect(collected.first[:output_tokens]).to eq(3)
      expect(collected.first[:stream]).to be true
      expect(collected.first[:usage_source]).to eq("stream_final")
    end

    it "parses built-in OpenAI-compatible providers like OpenRouter" do
      collected = events

      described_class.track_stream(provider: "openrouter", model: "gpt-4o") do |stream|
        stream.event({ "model" => "gpt-4o", "choices" => [{ "delta" => { "content" => "hi" } }] })
        stream.event({ "usage" => { "prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15 } })
      end

      expect(collected.size).to eq(1)
      expect(collected.first[:provider]).to eq("openrouter")
      expect(collected.first[:model]).to eq("gpt-4o")
      expect(collected.first[:input_tokens]).to eq(12)
      expect(collected.first[:output_tokens]).to eq(3)
      expect(collected.first[:usage_source]).to eq("stream_final")
    end

    it "parses configured OpenAI-compatible provider names" do
      collected = events

      LlmCostTracker.configure do |config|
        config.openai_compatible_providers["llm.example.com"] = "internal_gateway"
      end

      described_class.track_stream(provider: "internal_gateway", model: "custom-chat") do |stream|
        stream.event(
          {
            "model" => "custom-chat",
            "usage" => { "input_tokens" => 9, "output_tokens" => 2, "total_tokens" => 11 }
          }
        )
      end

      expect(collected.size).to eq(1)
      expect(collected.first[:provider]).to eq("internal_gateway")
      expect(collected.first[:model]).to eq("custom-chat")
      expect(collected.first[:input_tokens]).to eq(9)
      expect(collected.first[:output_tokens]).to eq(2)
      expect(collected.first[:usage_source]).to eq("stream_final")
    end

    it "uses explicit usage when provided even if events are empty" do
      collected = events

      described_class.track_stream(provider: "custom", model: "local-7b") do |stream|
        stream.usage(input_tokens: 50, output_tokens: 20)
      end

      expect(collected.first[:input_tokens]).to eq(50)
      expect(collected.first[:output_tokens]).to eq(20)
      expect(collected.first[:usage_source]).to eq("manual")
      expect(collected.first[:stream]).to be true
    end

    it "records an unknown-usage event when no parser can extract totals" do
      collected = events

      described_class.track_stream(provider: "custom", model: "local-7b") do |stream|
        stream.event({ "anything" => true })
      end

      expect(collected.first[:input_tokens]).to eq(0)
      expect(collected.first[:output_tokens]).to eq(0)
      expect(collected.first[:usage_source]).to eq("unknown")
      expect(collected.first[:stream]).to be true
    end

    it "still records and then re-raises when the block raises" do
      collected = events

      expect do
        described_class.track_stream(provider: "openai", model: "gpt-4o") do |stream|
          stream.usage(input_tokens: 1, output_tokens: 1)
          raise "network dropped"
        end
      end.to raise_error(RuntimeError, "network dropped")

      expect(collected.size).to eq(1)
      expect(collected.first[:tags]).to include(stream_errored: true)
    end
  end
end
