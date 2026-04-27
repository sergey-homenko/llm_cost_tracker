# frozen_string_literal: true

require "spec_helper"

module LlmCostTrackerIntegrationSpecTypes
  Usage = Struct.new(
    :input_tokens,
    :output_tokens,
    :prompt_tokens,
    :completion_tokens,
    :input_tokens_details,
    :output_tokens_details,
    :prompt_tokens_details,
    :completion_tokens_details,
    :cache_read_input_tokens,
    :cache_creation_input_tokens,
    :thinking_tokens,
    keyword_init: true
  )
  Details = Struct.new(:cached_tokens, :reasoning_tokens, keyword_init: true)
  Response = Struct.new(:id, :model, :usage, keyword_init: true)
  RubyLlmModel = Struct.new(:id, keyword_init: true)
  RubyLlmResponse = Struct.new(
    :id,
    :model_id,
    :input_tokens,
    :output_tokens,
    :cached_tokens,
    :cache_creation_tokens,
    :thinking_tokens,
    keyword_init: true
  )
end

RSpec.describe LlmCostTracker::Integrations do
  let(:usage_class) { LlmCostTrackerIntegrationSpecTypes::Usage }
  let(:details_class) { LlmCostTrackerIntegrationSpecTypes::Details }
  let(:response_class) { LlmCostTrackerIntegrationSpecTypes::Response }

  def capture_events
    events = []
    subscription = ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
      events << payload
    end
    yield events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  def configure_integration(name)
    LlmCostTracker.configure do |config|
      config.storage_backend = :custom
      config.custom_storage = ->(_event) {}
      config.unknown_pricing_behavior = :ignore
      config.instrument name
    end
  end

  def install_openai_fakes(response)
    stub_const("OpenAI", Module.new)
    stub_const("OpenAI::VERSION", "0.59.0")
    stub_const("OpenAI::Resources", Module.new)
    stub_const("OpenAI::Resources::Chat", Module.new)
    stub_const("OpenAI::Resources::Responses", Class.new do
      define_method(:initialize) { @response = response }
      define_method(:create) { |_params = {}| @response }
    end)
    stub_const("OpenAI::Resources::Chat::Completions", Class.new do
      define_method(:initialize) { @response = response }
      define_method(:create) { |_params = {}| @response }
    end)
  end

  def install_anthropic_fakes(message)
    stub_const("Anthropic", Module.new)
    stub_const("Anthropic::VERSION", "1.36.0")
    stub_const("Anthropic::Resources", Module.new)
    stub_const("Anthropic::Resources::Messages", Class.new do
      define_method(:initialize) { @message = message }
      define_method(:create) { |_params = {}| @message }
    end)
  end

  def install_ruby_llm_fakes(response)
    stub_const("RubyLLM", Module.new)
    stub_const("RubyLLM::VERSION", "1.14.1")
    stub_const("RubyLLM::Provider", Class.new do
      define_method(:initialize) do |provider: "openai"|
        @provider = provider
        @completion = response
        @embedding = response
        @transcription = response
      end

      define_method(:slug) { @provider }

      define_method(:complete) do |_messages = [], **_kwargs, &block|
        block&.call("chunk")
        @completion
      end

      define_method(:embed) do |_text, **_kwargs|
        @embedding
      end

      define_method(:transcribe) do |_audio_file, **_kwargs|
        @transcription
      end
    end)
  end

  it "tracks official OpenAI responses.create calls" do
    response = response_class.new(
      id: "resp_123",
      model: "gpt-4o",
      usage: usage_class.new(
        input_tokens: 100,
        output_tokens: 50,
        input_tokens_details: details_class.new(cached_tokens: 20),
        output_tokens_details: details_class.new(reasoning_tokens: 7)
      )
    )
    install_openai_fakes(response)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Responses.new.create(model: "gpt-4o")

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 80,
        output_tokens: 50,
        total_tokens: 150,
        cache_read_input_tokens: 20,
        hidden_output_tokens: 7,
        usage_source: "sdk_response",
        provider_response_id: "resp_123"
      )
      expect(events.first[:latency_ms]).to be >= 0
    end
  end

  it "tracks official OpenAI chat.completions.create calls" do
    response = response_class.new(
      id: "chatcmpl_123",
      usage: usage_class.new(
        prompt_tokens: 30,
        completion_tokens: 10,
        prompt_tokens_details: details_class.new(cached_tokens: 4),
        completion_tokens_details: details_class.new(reasoning_tokens: 2)
      )
    )
    install_openai_fakes(response)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Chat::Completions.new.create(model: "gpt-4o")

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 26,
        output_tokens: 10,
        total_tokens: 40,
        cache_read_input_tokens: 4,
        hidden_output_tokens: 2,
        provider_response_id: "chatcmpl_123"
      )
    end
  end

  it "tracks official Anthropic messages.create calls" do
    message = response_class.new(
      id: "msg_123",
      model: "claude-sonnet-4-5-20250929",
      usage: usage_class.new(
        input_tokens: 120,
        output_tokens: 35,
        cache_read_input_tokens: 50,
        cache_creation_input_tokens: 11,
        thinking_tokens: 6
      )
    )
    install_anthropic_fakes(message)
    configure_integration(:anthropic)

    capture_events do |events|
      Anthropic::Resources::Messages.new.create(model: "claude-sonnet-4-5-20250929")

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "anthropic",
        model: "claude-sonnet-4-5-20250929",
        input_tokens: 120,
        output_tokens: 35,
        cache_read_input_tokens: 50,
        cache_write_input_tokens: 11,
        hidden_output_tokens: 6,
        usage_source: "sdk_response",
        provider_response_id: "msg_123"
      )
    end
  end

  it "does not record when usage is missing" do
    install_anthropic_fakes(response_class.new(id: "msg_123", model: "claude-sonnet-4-5-20250929"))
    configure_integration(:anthropic)

    capture_events do |events|
      Anthropic::Resources::Messages.new.create(model: "claude-sonnet-4-5-20250929")

      expect(events).to be_empty
    end
  end

  it "tracks RubyLLM chat completions through the provider contract" do
    response = LlmCostTrackerIntegrationSpecTypes::RubyLlmResponse.new(
      id: "msg_123",
      model_id: "gpt-4o-2024-08-06",
      input_tokens: 100,
      output_tokens: 30,
      cached_tokens: 25,
      cache_creation_tokens: 5,
      thinking_tokens: 8
    )
    model = LlmCostTrackerIntegrationSpecTypes::RubyLlmModel.new(id: "gpt-4o")
    install_ruby_llm_fakes(response)
    configure_integration(:ruby_llm)

    capture_events do |events|
      streamed = []
      RubyLLM::Provider.new.complete([], model: model, tools: {}, temperature: nil) { |chunk| streamed << chunk }

      expect(events.size).to eq(1)
      expect(streamed).to eq(["chunk"])
      expect(events.first).to include(
        provider: "openai",
        model: "gpt-4o-2024-08-06",
        input_tokens: 75,
        output_tokens: 30,
        cache_read_input_tokens: 25,
        cache_write_input_tokens: 5,
        hidden_output_tokens: 8,
        stream: true,
        usage_source: "ruby_llm",
        provider_response_id: "msg_123"
      )
    end
  end

  it "tracks RubyLLM embeddings through the provider contract" do
    response = LlmCostTrackerIntegrationSpecTypes::RubyLlmResponse.new(
      model_id: "text-embedding-3-small",
      input_tokens: 42
    )
    install_ruby_llm_fakes(response)
    configure_integration(:ruby_llm)

    capture_events do |events|
      RubyLLM::Provider.new.embed("hello", model: "text-embedding-3-small", dimensions: nil)

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "text-embedding-3-small",
        input_tokens: 42,
        output_tokens: 0,
        stream: false,
        usage_source: "ruby_llm"
      )
    end
  end

  it "marks RubyLLM stream keyword calls as streaming" do
    response = LlmCostTrackerIntegrationSpecTypes::RubyLlmResponse.new(
      input_tokens: 100,
      output_tokens: 30
    )
    install_ruby_llm_fakes(response)
    configure_integration(:ruby_llm)

    capture_events do |events|
      RubyLLM::Provider.new.complete([], model: "gpt-4o", stream: true)

      expect(events.size).to eq(1)
      expect(events.first).to include(
        model: "gpt-4o",
        stream: true,
        usage_source: "ruby_llm"
      )
    end
  end

  it "raises when an enabled integration cannot satisfy its install contract" do
    stub_const("RubyLLM", Module.new)
    stub_const("RubyLLM::VERSION", "1.13.0")

    expect do
      configure_integration(:ruby_llm)
    end.to raise_error(
      LlmCostTracker::Error,
      /ruby_llm integration cannot be installed: ruby_llm >= 1\.14\.1 is required, detected 1\.13\.0/
    )
  end

  it "raises when an enabled integration target method is missing" do
    stub_const("RubyLLM", Module.new)
    stub_const("RubyLLM::VERSION", "1.14.1")
    stub_const("RubyLLM::Provider", Class.new do
      define_method(:slug) { "openai" }
      define_method(:complete) { |_messages = [], **_kwargs| nil }
      define_method(:embed) { |_text, **_kwargs| nil }
    end)

    expect do
      configure_integration(:ruby_llm)
    end.to raise_error(
      LlmCostTracker::Error,
      /ruby_llm integration cannot be installed: RubyLLM::Provider#transcribe is not available/
    )
  end

  it "raises when a loaded optional integration target is incompatible" do
    install_anthropic_fakes(response_class.new(usage: usage_class.new(input_tokens: 1, output_tokens: 1)))
    stub_const("Anthropic::Resources::Beta", Module.new)
    stub_const("Anthropic::Resources::Beta::Messages", Class.new)

    expect do
      configure_integration(:anthropic)
    end.to raise_error(
      LlmCostTracker::Error,
      /anthropic integration cannot be installed: Anthropic::Resources::Beta::Messages#create is not available/
    )
  end

  it "does not record after the integration is disabled by configuration reset" do
    response = response_class.new(
      id: "resp_123",
      model: "gpt-4o",
      usage: usage_class.new(input_tokens: 1, output_tokens: 1)
    )
    install_openai_fakes(response)
    configure_integration(:openai)
    LlmCostTracker.reset_configuration!

    capture_events do |events|
      OpenAI::Resources::Responses.new.create(model: "gpt-4o")

      expect(events).to be_empty
    end
  end

  it "installs idempotently" do
    response = response_class.new(
      id: "resp_123",
      model: "gpt-4o",
      usage: usage_class.new(input_tokens: 1, output_tokens: 1)
    )
    install_openai_fakes(response)
    configure_integration(:openai)
    LlmCostTracker::Integrations.install!

    capture_events do |events|
      OpenAI::Resources::Responses.new.create(model: "gpt-4o")

      expect(events.size).to eq(1)
    end
  end

  it "reports missing enabled SDK integrations in doctor" do
    expect(LlmCostTracker::Integrations::Registry.checks([:anthropic]).first.message)
      .to include("anthropic integration cannot be installed")
  end

  it "expands the all instrumentation alias" do
    install_openai_fakes(response_class.new(usage: usage_class.new(input_tokens: 1, output_tokens: 1)))
    install_anthropic_fakes(response_class.new(usage: usage_class.new(input_tokens: 1, output_tokens: 1)))
    install_ruby_llm_fakes(LlmCostTrackerIntegrationSpecTypes::RubyLlmResponse.new(input_tokens: 1, output_tokens: 1))

    LlmCostTracker.configure { |config| config.instrument :all }

    expect(LlmCostTracker.configuration.instrumented_integrations).to eq(%i[openai anthropic ruby_llm])
    expect { LlmCostTracker.configuration.instrumented_integrations << :gemini }.to raise_error(FrozenError)
  end

  it "rejects unknown integrations" do
    expect do
      LlmCostTracker.configure { |config| config.instrument :gemini }
    end.to raise_error(LlmCostTracker::Error, /Unknown integration: :gemini/)
  end
end
