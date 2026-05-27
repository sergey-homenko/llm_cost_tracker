# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/capture/stream_collector"

RSpec.describe LlmCostTracker do
  describe LlmCostTracker::Capture::StreamCollector do
    it "strips b64_json payload data before counting bytes so an OpenAI image_generation.completed event with a multi-megabyte image does not overflow the buffer and lose the usage chunk" do
      collector = described_class.new(provider: "openai", model: "gpt-image-2")
      huge_blob = "A" * (LlmCostTracker::Capture::Stream::LIMIT_BYTES + 1024)
      collector.event(
        {
          "type" => "image_generation.completed",
          "b64_json" => huge_blob,
          "usage" => { "input_tokens" => 10, "output_tokens" => 1000, "total_tokens" => 1010 }
        },
        type: "image_generation.completed"
      )

      expect(collector.instance_variable_get(:@overflowed)).to be false
      stored = collector.instance_variable_get(:@events).first
      expect(stored[:data]).not_to have_key("b64_json")
      expect(stored[:data]["usage"]).to include("input_tokens" => 10, "output_tokens" => 1000)
    end

    it "strips partial_image_b64 from Responses image_generation_call.partial_image events so the Responses image-gen tool stream also stays under the buffer cap" do
      collector = described_class.new(provider: "openai", model: "gpt-5")
      huge_blob = "B" * (LlmCostTracker::Capture::Stream::LIMIT_BYTES + 1024)
      collector.event(
        {
          "type" => "response.image_generation_call.partial_image",
          "item_id" => "ig_1",
          "partial_image_b64" => huge_blob,
          "partial_image_index" => 0
        },
        type: "response.image_generation_call.partial_image"
      )

      expect(collector.instance_variable_get(:@overflowed)).to be false
      stored = collector.instance_variable_get(:@events).first
      expect(stored[:data]).not_to have_key("partial_image_b64")
      expect(stored[:data]).to include("item_id" => "ig_1")
    end

    it "drops any string field larger than the heavy-string threshold so unknown blob fields (audio delta bytes, future blob fields) cannot overflow the buffer" do
      collector = described_class.new(provider: "openai", model: "gpt-4o")
      huge_unknown = "C" * (32 * 1024)
      collector.event(
        {
          "type" => "response.audio.delta",
          "delta" => huge_unknown,
          "item_id" => "audio_1"
        },
        type: "response.audio.delta"
      )

      expect(collector.instance_variable_get(:@overflowed)).to be false
      stored = collector.instance_variable_get(:@events).first
      expect(stored[:data]["delta"]).to eq("")
      expect(stored[:data]["item_id"]).to eq("audio_1")
    end

    it "tags the recorded event with stream_errored: true when errored is passed" do
      collector = described_class.new(provider: "openai", model: "gpt-4o")
      collector.usage(input_tokens: 5, output_tokens: 1)

      received_metadata = nil
      allow(LlmCostTracker::Tracker).to receive(:record) do |metadata:, **_, &block|
        received_metadata = metadata
        block&.call
        nil
      end

      collector.finish!(errored: true)
      expect(received_metadata).to include(stream_errored: true)
    end

    it "passes a nil request body to the parser when the original request cannot be JSON-serialized" do
      unserializable = Object.new
      def unserializable.to_json(*)
        raise StandardError, "cannot serialize"
      end
      collector = described_class.new(provider: "openai", model: "gpt-4o", request: unserializable)
      collector.event({ "id" => "chatcmpl_x", "model" => "gpt-4o",
                        "usage" => { "prompt_tokens" => 5, "completion_tokens" => 2, "total_tokens" => 7 } })

      received_request_body = :unset
      allow_any_instance_of(LlmCostTracker::Providers::Openai::Parser).to receive(:parse_stream) do |_, request_body:, **_|
        received_request_body = request_body
        nil
      end
      allow(LlmCostTracker::Tracker).to receive(:record) { |&block| block&.call; nil }

      collector.finish!(errored: false)
      expect(received_request_body).to be_nil
    end

    it "does not retry after Tracker.record persisted but Budget.check! raised" do
      collector = described_class.new(provider: "openai", model: "gpt-4o")
      collector.usage(input_tokens: 5, output_tokens: 1)

      record_calls = 0
      allow(LlmCostTracker::Tracker).to receive(:record) do |**_, &block|
        record_calls += 1
        block&.call
        raise LlmCostTracker::BudgetExceededError.new(budget_type: :monthly, total: 1, budget: 0.5)
      end

      expect { collector.finish!(errored: false) }.to raise_error(LlmCostTracker::BudgetExceededError)
      expect { collector.finish!(errored: false) }.not_to raise_error
      expect(record_calls).to eq(1)
    end
  end

  describe ".track" do
    it "does not record or enforce budget when tracking is disabled" do
      collected = []
      ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
        collected << payload
      end

      LlmCostTracker.configure do |config|
        config.enabled = false
      end

      result = described_class.track(
        provider: "openai",
        model: "gpt-4o",
        tokens: { input: 10, output: 5 },
        enforce_budget: true
      )

      expect(result).to be_nil
      expect(collected).to be_empty
    end
  end

  describe ".track_stream" do
    before do
      allow(LlmCostTracker::Ingestion::Inbox).to receive(:save).and_return(true)
      allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_return(true)
    end

    let(:events) do
      captured = []
      ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
        captured << payload
      end
      captured
    end

    it "exposes stream state while open" do
      stream = LlmCostTracker::Capture::StreamCollector.new(
        provider: "custom",
        model: "initial-model",
        provider_response_id: "resp_initial",
        metadata: { feature: "stream" }
      )

      stream.model = "updated-model"

      expect(stream.model).to eq("updated-model")
      expect(stream.provider_response_id).to eq("resp_initial")
      expect(stream.metadata).to eq(feature: "stream")
    end

    it "parses OpenAI-shaped chunks via the matching provider parser" do
      collected = events

      described_class.track_stream(provider: "openai", model: "gpt-4o", tags: { feature: "stream" }) do |stream|
        stream.event({ "model" => "gpt-4o", "choices" => [{ "delta" => { "content" => "hi" } }] })
        stream.event({ "usage" => { "prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15 } })
      end

      expect(collected.size).to eq(1)
      expect(collected.first[:provider]).to eq("openai")
      expect(collected.first.dig(:token_usage, :input_tokens)).to eq(12)
      expect(collected.first.dig(:token_usage, :output_tokens)).to eq(3)
      expect(collected.first[:stream]).to be true
      expect(collected.first[:usage_source]).to eq("stream_final")
      expect(collected.first[:tags]).to include(feature: "stream")
    end

    it "infers the model from stream events when no model is passed" do
      collected = events

      described_class.track_stream(provider: "openai") do |stream|
        stream.event({ "model" => "gpt-5.4-mini", "choices" => [{ "delta" => { "content" => "hi" } }] })
        stream.event({ "usage" => { "prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15 } })
      end

      expect(collected.first[:model]).to eq("gpt-5.4-mini")
      expect(collected.first[:usage_source]).to eq("stream_final")
    end

    it "uses unknown when no stream model is available" do
      collected = events

      described_class.track_stream(provider: "openai") do |stream|
        stream.event({ "usage" => { "prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15 } })
      end

      expect(collected.first[:model]).to eq("unknown")
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
      expect(collected.first.dig(:token_usage, :input_tokens)).to eq(12)
      expect(collected.first.dig(:token_usage, :output_tokens)).to eq(3)
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
      expect(collected.first.dig(:token_usage, :input_tokens)).to eq(9)
      expect(collected.first.dig(:token_usage, :output_tokens)).to eq(2)
      expect(collected.first[:usage_source]).to eq("stream_final")
    end

    it "uses explicit usage when provided even if events are empty" do
      collected = events

      described_class.track_stream(provider: "custom", model: "local-7b") do |stream|
        stream.usage(input_tokens: 50, output_tokens: 20, provider_response_id: "custom_resp_123")
      end

      expect(collected.first.dig(:token_usage, :input_tokens)).to eq(50)
      expect(collected.first.dig(:token_usage, :output_tokens)).to eq(20)
      expect(collected.first[:usage_source]).to eq("manual")
      expect(collected.first[:provider_response_id]).to eq("custom_resp_123")
      expect(collected.first[:stream]).to be true
    end

    it "carries provider capture dimensions from explicit stream usage" do
      collected = events

      described_class.track_stream(
        provider: "custom",
        model: "local-7b",
        provider_project_id: "initial",
        pricing_mode: :batch
      ) do |stream|
        stream.usage(
          input_tokens: 50,
          output_tokens: 20,
          provider_project_id: " project-stream ",
          provider_api_key_id: " key-stream ",
          provider_workspace_id: " workspace-stream "
        )
      end

      expect(collected.first[:provider_project_id]).to eq("project-stream")
      expect(collected.first[:provider_api_key_id]).to eq("key-stream")
      expect(collected.first[:provider_workspace_id]).to eq("workspace-stream")
      expect(collected.first[:pricing_mode]).to eq(:batch)
    end

    it "normalizes provider capture dimensions from parsed stream usage" do
      collected = events

      described_class.track_stream(
        provider: "openai",
        model: "gpt-4o",
        provider_project_id: " project-stream ",
        provider_api_key_id: " key-stream ",
        provider_workspace_id: " workspace-stream ",
        pricing_mode: :batch
      ) do |stream|
        stream.event({ "usage" => { "prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15 } })
      end

      expect(collected.first[:provider_project_id]).to eq("project-stream")
      expect(collected.first[:provider_api_key_id]).to eq("key-stream")
      expect(collected.first[:provider_workspace_id]).to eq("workspace-stream")
      expect(collected.first[:pricing_mode]).to eq(:batch)
    end

    it "keeps provider parser batch capture when stream dimensions are not explicit" do
      collected = events

      described_class.track_stream(provider: "openai", model: "gpt-4o") do |stream|
        stream.event(
          {
            "type" => "response.completed",
            "response" => {
              "model" => "gpt-4o",
              "service_tier" => "batch",
              "usage" => { "input_tokens" => 12, "output_tokens" => 3, "total_tokens" => 15 }
            }
          }
        )
      end

      expect(collected.first[:pricing_mode]).to eq(:batch)
    end

    it "keeps scoped tags from when the stream started" do
      collected = events
      collector = LlmCostTracker.with_tags(user_id: 42, feature: "chat") do
        LlmCostTracker::Capture::StreamCollector.new(provider: "custom", model: "local-7b").tap do |stream|
          stream.usage(input_tokens: 50, output_tokens: 20)
        end
      end

      LlmCostTracker.with_tags(user_id: 99, feature: "other") do
        collector.finish!
      end

      expect(collected.first[:tags]).to include(user_id: 42, feature: "chat")
    end

    it "records an unknown-usage event when no parser can extract totals" do
      collected = events

      described_class.track_stream(provider: "custom", model: "local-7b") do |stream|
        stream.event({ "anything" => true })
      end

      expect(collected.first.dig(:token_usage, :input_tokens)).to eq(0)
      expect(collected.first.dig(:token_usage, :output_tokens)).to eq(0)
      expect(collected.first[:usage_source]).to eq("unknown")
      expect(collected.first[:stream]).to be true
    end

    it "falls back to unknown usage when buffered stream events exceed the capture cap" do
      collected = events
      stub_const("LlmCostTracker::Capture::Stream::LIMIT_BYTES", 10)

      described_class.track_stream(provider: "openai", model: "gpt-4o") do |stream|
        stream.event({ "usage" => { "prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15 } })
      end

      expect(collected.first.dig(:token_usage, :input_tokens)).to eq(0)
      expect(collected.first.dig(:token_usage, :output_tokens)).to eq(0)
      expect(collected.first[:usage_source]).to eq("unknown")
    end

    it "keeps a stream event that fits the byte cap" do
      collected = events
      data = { "usage" => { "prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15 } }

      described_class.track_stream(provider: "openai", model: "gpt-4o") do |stream|
        stream.event(data)
      end

      expect(collected.first.dig(:token_usage, :input_tokens)).to eq(12)
      expect(collected.first.dig(:token_usage, :output_tokens)).to eq(3)
      expect(collected.first[:usage_source]).to eq("stream_final")
    end

    it "falls back to unknown usage when a stream event cannot be serialized" do
      collected = events
      data = []
      data << data

      described_class.track_stream(provider: "custom", model: "local-7b") do |stream|
        stream.event(data)
      end

      expect(collected.first.dig(:token_usage, :input_tokens)).to eq(0)
      expect(collected.first.dig(:token_usage, :output_tokens)).to eq(0)
      expect(collected.first[:usage_source]).to eq("unknown")
    end

    it "uses explicit usage when provided after the capture cap is exceeded" do
      collected = events
      stub_const("LlmCostTracker::Capture::Stream::LIMIT_BYTES", 10)

      described_class.track_stream(provider: "openai", model: "gpt-4o") do |stream|
        stream.event({ "usage" => { "prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15 } })
        stream.usage(input_tokens: 7, output_tokens: 4)
      end

      expect(collected.first.dig(:token_usage, :input_tokens)).to eq(7)
      expect(collected.first.dig(:token_usage, :output_tokens)).to eq(4)
      expect(collected.first[:usage_source]).to eq("manual")
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

    it "accepts a provider response id during stream collection" do
      collected = events

      described_class.track_stream(provider: "openai", model: "gpt-4o") do |stream|
        stream.provider_response_id = "chatcmpl_manual_123"
        stream.event({ "usage" => { "prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15 } })
      end

      expect(collected.first[:provider_response_id]).to eq("chatcmpl_manual_123")
    end

    it "releases the recording slot when Tracker.record raises so finish! can be retried" do
      collector = LlmCostTracker::Capture::StreamCollector.new(provider: "openai", model: "gpt-4o")
      collector.usage(input_tokens: 5, output_tokens: 1)

      first_call = true
      allow(LlmCostTracker::Tracker).to receive(:record) do |**args|
        if first_call
          first_call = false
          raise "transient ingestion error"
        end
        events << args
        :ok
      end

      expect { collector.finish! }.to raise_error(RuntimeError, "transient ingestion error")
      expect(collector.finish!).to eq(:ok)
      expect(events.size).to eq(1)
    end

    it "still yields the stream object but does not record or enforce budget when tracking is disabled" do
      collected = events
      yielded = false

      LlmCostTracker.configure do |config|
        config.enabled = false
      end

      result = described_class.track_stream(provider: "openai", model: "gpt-4o", enforce_budget: true) do |stream|
        yielded = true
        stream.usage(input_tokens: 1, output_tokens: 1)
      end

      expect(yielded).to be true
      expect(result).to be_nil
      expect(collected).to be_empty
    end
  end
end
