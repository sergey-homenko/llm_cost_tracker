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
      config.instrument name
    end
  end

  def install_openai_fakes(response)
    stub_const("OpenAI", Module.new)
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
    stub_const("Anthropic::Resources", Module.new)
    stub_const("Anthropic::Resources::Messages", Class.new do
      define_method(:initialize) { @message = message }
      define_method(:create) { |_params = {}| @message }
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
    LlmCostTracker.configure { |config| config.instrument :anthropic }

    expect(LlmCostTracker::Doctor.report).to include("[warn] anthropic: anthropic SDK classes are not loaded")
  end

  it "expands the all instrumentation alias" do
    LlmCostTracker.configure { |config| config.instrument :all }

    expect(LlmCostTracker.configuration.instrumented_integrations).to eq(%i[openai anthropic])
    expect { LlmCostTracker.configuration.instrumented_integrations << :gemini }.to raise_error(FrozenError)
  end

  it "rejects unknown integrations" do
    expect do
      LlmCostTracker.configure { |config| config.instrument :gemini }
    end.to raise_error(LlmCostTracker::Error, /Unknown integration: :gemini/)
  end
end
