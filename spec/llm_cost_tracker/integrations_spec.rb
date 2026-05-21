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
    :input_token_details,
    :output_token_details,
    :prompt_tokens_details,
    :completion_tokens_details,
    :cache_read_input_tokens,
    :cache_creation_input_tokens,
    :cache_creation,
    :thinking_tokens,
    :service_tier,
    :speed,
    :inference_geo,
    :server_tool_use,
    keyword_init: true
  ) { include SdkFixtureDeepToH }
  ServerToolUse = Struct.new(:web_search_requests, :code_execution_requests, keyword_init: true) { include SdkFixtureDeepToH }
  OutputItem = Struct.new(:type, :id, :status, :container_id, :action, keyword_init: true) { include SdkFixtureDeepToH }
  OutputAction = Struct.new(:type, keyword_init: true) { include SdkFixtureDeepToH }
  Details = Struct.new(:cached_tokens, :reasoning_tokens, :audio_tokens, keyword_init: true) { include SdkFixtureDeepToH }
  Response = Struct.new(:id, :model, :usage, :service_tier, :output, keyword_init: true) { include SdkFixtureDeepToH }
  BrokenStreamEvent = Class.new do
    def to_h
      raise "boom"
    end
  end
  StreamEvent = Struct.new(:type, :id, :model, :usage, :response, :message, keyword_init: true) do
    def to_h
      {
        type: type,
        id: id,
        model: model,
        usage: usage,
        response: response,
        message: message
      }.compact
    end
  end
  Stream = Class.new do
    include Enumerable

    def initialize(events)
      @iterator = events.each
    end

    def each(&block)
      raise ArgumentError, "A block must be given to #each" unless block

      @iterator.each(&block)
    end

    def text
      Enumerator.new do |yielder|
        @iterator.each { |event| yielder << event.type.to_s }
      end
    end

  end
  FailingStream = Class.new do
    include Enumerable

    def initialize(events, error)
      @iterator = Enumerator.new do |yielder|
        events.each { |event| yielder << event }
        raise error
      end
    end

    def each(&block)
      raise ArgumentError, "A block must be given to #each" unless block

      @iterator.each(&block)
    end
  end
  EachOnlyStream = Class.new do
    include Enumerable

    def initialize(events)
      @events = events
    end

    def each(&block)
      return enum_for(:each) unless block

      @events.each(&block)
    end
  end
  RubyLlmModel = Struct.new(:id, keyword_init: true)
  RubyLlmResponse = Struct.new(
    :id,
    :model_id,
    :input_tokens,
    :output_tokens,
    :cached_tokens,
    :cache_creation_tokens,
    :thinking_tokens,
    :reasoning_tokens,
    :service_tier,
    :pricing_mode,
    :provider_response_id,
    :raw,
    keyword_init: true
  )
  RubyLlmImage = Struct.new(:model_id, :usage, :provider_response_id, keyword_init: true)
  RubyLlmModeration = Struct.new(:id, :model_id, keyword_init: true)
  EmbeddingResponse = Struct.new(:model, :usage, keyword_init: true) { include SdkFixtureDeepToH }
  EmbeddingUsage = Struct.new(:prompt_tokens, :total_tokens, keyword_init: true) { include SdkFixtureDeepToH }
  ImagesResponse = Struct.new(:created, :usage, keyword_init: true) { include SdkFixtureDeepToH }
  ImagesUsage = Struct.new(:input_tokens, :output_tokens, :total_tokens, keyword_init: true) { include SdkFixtureDeepToH }
  TranscriptionResponse = Struct.new(:text, :usage, keyword_init: true) { include SdkFixtureDeepToH }
  TranscriptionTokensUsage = Struct.new(
    :type, :input_tokens, :output_tokens, :total_tokens, :input_token_details, keyword_init: true
  ) { include SdkFixtureDeepToH }
  TranscriptionInputTokenDetails = Struct.new(:audio_tokens, :text_tokens, keyword_init: true) { include SdkFixtureDeepToH }
  TranscriptionDurationUsage = Struct.new(:type, :seconds, keyword_init: true) { include SdkFixtureDeepToH }
  ModerationResponse = Struct.new(:id, :model, :results, keyword_init: true) { include SdkFixtureDeepToH }
end

RSpec.describe LlmCostTracker::Integrations do
  let(:usage_class) { LlmCostTrackerIntegrationSpecTypes::Usage }
  let(:details_class) { LlmCostTrackerIntegrationSpecTypes::Details }
  let(:response_class) { LlmCostTrackerIntegrationSpecTypes::Response }
  let(:stream_event_class) { LlmCostTrackerIntegrationSpecTypes::StreamEvent }
  let(:stream_class) { LlmCostTrackerIntegrationSpecTypes::Stream }
  let(:failing_stream_class) { LlmCostTrackerIntegrationSpecTypes::FailingStream }
  let(:each_only_stream_class) { LlmCostTrackerIntegrationSpecTypes::EachOnlyStream }

  def capture_events
    events = []
    subscription = ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
      events << payload.merge(payload.fetch(:token_usage, {}))
    end
    yield events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  def configure_integration(name)
    allow(LlmCostTracker::Ingestion::Inbox).to receive(:save).and_return(true)
    allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_return(true)
    LlmCostTracker.configure do |config|
      config.unknown_pricing_behavior = :ignore
      config.instrument name
    end
  end

  def install_openai_fakes(response, stream: nil, embedding: response, image: response,
                           transcription: response, speech: response, moderation: response)
    stub_const("OpenAI", Module.new)
    stub_const("OpenAI::VERSION", "0.59.0")
    stub_const("OpenAI::Resources", Module.new)
    stub_const("OpenAI::Resources::Chat", Module.new)
    stub_const("OpenAI::Resources::Audio", Module.new)
    stub_const("OpenAI::Resources::Responses", Class.new do
      define_method(:initialize) do
        @response = response
        @stream = stream
      end
      define_method(:create) { |_params = {}| @response }
      define_method(:stream) { |_params = {}| @stream }
      define_method(:stream_raw) { |_params = {}| @stream }
      define_method(:retrieve_streaming) { |_response_id, _params = {}| @stream }
    end)
    stub_const("OpenAI::Resources::Chat::Completions", Class.new do
      define_method(:initialize) do
        @response = response
        @stream = stream
      end
      define_method(:create) { |_params = {}| @response }
      define_method(:stream) { |_params = {}| @stream }
      define_method(:stream_raw) { |_params = {}| @stream }
    end)
    stub_const("OpenAI::Resources::Embeddings", Class.new do
      define_method(:initialize) { @embedding = embedding }
      define_method(:create) { |_params = {}| @embedding }
    end)
    stub_const("OpenAI::Resources::Images", Class.new do
      define_method(:initialize) do
        @image = image
        @stream = stream
      end
      define_method(:generate) { |_params = {}| @image }
      define_method(:edit) { |_params = {}| @image }
      define_method(:create_variation) { |_params = {}| @image }
      define_method(:generate_stream_raw) { |_params = {}| @stream }
      define_method(:edit_stream_raw) { |_params = {}| @stream }
    end)
    stub_const("OpenAI::Resources::Audio::Transcriptions", Class.new do
      define_method(:initialize) do
        @transcription = transcription
        @stream = stream
      end
      define_method(:create) { |_params = {}| @transcription }
      define_method(:create_streaming) { |_params = {}| @stream }
    end)
    stub_const("OpenAI::Resources::Audio::Translations", Class.new do
      define_method(:initialize) { @translation = transcription }
      define_method(:create) { |_params = {}| @translation }
    end)
    stub_const("OpenAI::Resources::Audio::Speech", Class.new do
      define_method(:initialize) { @speech = speech }
      define_method(:create) { |_params = {}| @speech }
    end)
    stub_const("OpenAI::Resources::Moderations", Class.new do
      define_method(:initialize) { @moderation = moderation }
      define_method(:create) { |_params = {}| @moderation }
    end)
  end

  def install_anthropic_fakes(message, stream: nil)
    stub_const("Anthropic", Module.new)
    stub_const("Anthropic::VERSION", "1.36.0")
    stub_const("Anthropic::Resources", Module.new)
    stub_const("Anthropic::Resources::Messages", Class.new do
      define_method(:initialize) do
        @message = message
        @stream = stream
      end
      define_method(:create) { |_params = {}| @message }
      define_method(:stream) { |_params = {}| @stream }
      define_method(:stream_raw) { |_params = {}| @stream }
    end)
  end

  def install_ruby_llm_fakes(response, image: response, moderation: response)
    stub_const("RubyLLM", Module.new)
    stub_const("RubyLLM::VERSION", "1.14.1")
    stub_const("RubyLLM::Provider", Class.new do
      define_method(:initialize) do |provider: "openai"|
        @provider = provider
        @completion = response
        @embedding = response
        @transcription = response
        @image = image
        @moderation = moderation
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

      define_method(:paint) do |_prompt, **_kwargs|
        @image
      end

      define_method(:moderate) do |_input, **_kwargs|
        @moderation
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
        usage_source: :sdk_response,
        provider_response_id: "resp_123"
      )
      expect(events.first[:latency_ms]).to be >= 0
    end
  end

  it "tags SDK responses as azure_openai when the OpenAI client is configured with an Azure base_url" do
    response = response_class.new(
      id: "resp_az", model: "gpt-4o-2024-08-06",
      usage: usage_class.new(input_tokens: 80, output_tokens: 20)
    )
    azure_client = Struct.new(:base_url).new("https://acme.openai.azure.com/openai")
    install_openai_fakes(response)
    OpenAI::Resources::Responses.class_eval do
      define_method(:initialize) do
        @client = azure_client
        @response = response
      end
    end
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Responses.new.create(model: "gpt-4o-2024-08-06")
      expect(events.first[:provider]).to eq("azure_openai")
    end
  end

  it "tags streamed SDK responses as azure_openai under an Azure base_url" do
    stream = stream_class.new([
                                stream_event_class.new(
                                  type: :"response.completed",
                                  response: {
                                    id: "resp_az_stream", model: "gpt-4o-mini",
                                    usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 }
                                  }
                                )
                              ])
    azure_client = Struct.new(:base_url).new("https://acme.openai.azure.com/openai")
    install_openai_fakes(response_class.new, stream: stream)
    OpenAI::Resources::Responses.class_eval do
      define_method(:initialize) do
        @client = azure_client
        @stream = stream
      end
    end
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Responses.new.stream(model: "gpt-4o-mini").text.to_a

      expect(events.first[:provider]).to eq("azure_openai")
      expect(events.first[:stream]).to be true
    end
  end

  it "tags SDK image / transcription / speech / moderation calls as azure_openai under an Azure base_url" do
    detailed_usage = Struct.new(
      :input_tokens, :output_tokens, :total_tokens, :input_tokens_details, keyword_init: true
    ) { include SdkFixtureDeepToH }
    detail_struct = Struct.new(:image_tokens, :cached_tokens, keyword_init: true) { include SdkFixtureDeepToH }
    images_class = LlmCostTrackerIntegrationSpecTypes::ImagesResponse
    image = images_class.new(
      created: 1_700_000_000,
      usage: detailed_usage.new(input_tokens: 50, output_tokens: 1024, total_tokens: 1074,
                                input_tokens_details: detail_struct.new(image_tokens: 0, cached_tokens: 0))
    )
    azure_client = Struct.new(:base_url).new("https://acme.openai.azure.com/openai")
    install_openai_fakes(response_class.new, image: image)
    OpenAI::Resources::Images.class_eval do
      define_method(:initialize) do
        @image = image
        @client = azure_client
      end
    end
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Images.new.generate(prompt: "a cat", model: "gpt-image-1", size: "1024x1024")
      expect(events.first[:provider]).to eq("azure_openai")
    end
  end

  it "tags SDK responses with data_residency pricing mode when the client uses us.api.openai.com on an uplifted model" do
    response = response_class.new(
      id: "resp_dr", model: "gpt-5.4",
      usage: usage_class.new(input_tokens: 100, output_tokens: 50)
    )
    regional_client = Struct.new(:base_url).new("https://us.api.openai.com/v1")
    install_openai_fakes(response)
    OpenAI::Resources::Responses.class_eval do
      define_method(:initialize) do
        @client = regional_client
        @response = response
      end
    end
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Responses.new.create(model: "gpt-5.4")
      expect(events.first[:pricing_mode]).to eq(:data_residency)
    end
  end

  it "tracks official OpenAI response audio tokens" do
    response = response_class.new(
      id: "resp_audio",
      model: "gpt-realtime-1.5",
      usage: usage_class.new(
        input_tokens: 120,
        output_tokens: 70,
        input_token_details: details_class.new(cached_tokens: 20, audio_tokens: 30),
        output_token_details: details_class.new(reasoning_tokens: 5, audio_tokens: 10)
      )
    )
    install_openai_fakes(response)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Responses.new.create(model: "gpt-realtime-1.5")

      expect(events.size).to eq(1)
      expect(events.first).to include(
        model: "gpt-realtime-1.5",
        input_tokens: 70,
        cache_read_input_tokens: 20,
        audio_input_tokens: 30,
        output_tokens: 60,
        audio_output_tokens: 10,
        hidden_output_tokens: 5
      )
    end
  end

  it "captures official OpenAI response service tiers" do
    response = response_class.new(
      id: "resp_123",
      model: "gpt-4o",
      service_tier: "priority",
      usage: usage_class.new(input_tokens: 100, output_tokens: 50)
    )
    install_openai_fakes(response)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Responses.new.create(model: "gpt-4o")

      expect(events.size).to eq(1)
      expect(events.first[:pricing_mode]).to eq(:priority)
    end
  end

  it "passes the request payload to Tracker.enforce_budget! for pre-send estimation from SDK patches" do
    response = response_class.new(id: "chatcmpl_x", usage: usage_class.new(prompt_tokens: 1, completion_tokens: 1))
    install_openai_fakes(response)
    configure_integration(:openai)
    allow(LlmCostTracker::Tracker).to receive(:enforce_budget!).and_call_original

    OpenAI::Resources::Chat::Completions.new.create(model: "gpt-4o", messages: [{ role: "user", content: "hello" }])

    expect(LlmCostTracker::Tracker).to have_received(:enforce_budget!).with(
      provider: "openai",
      model: "gpt-4o",
      request: include(model: "gpt-4o")
    )
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

  it "tracks official OpenAI responses.stream calls" do
    stream = stream_class.new([
                                stream_event_class.new(
                                  type: :"response.created",
                                  response: { id: "resp_456", model: "gpt-5-mini" }
                                ),
                                stream_event_class.new(
                                  type: :"response.completed",
                                  response: {
                                    id: "resp_456",
                                    model: "gpt-5-mini",
                                    usage: {
                                      input_tokens: 100,
                                      input_tokens_details: { cached_tokens: 25 },
                                      output_tokens: 40,
                                      output_tokens_details: { reasoning_tokens: 9 },
                                      total_tokens: 140
                                    }
                                  }
                                )
                              ])
    install_openai_fakes(response_class.new, stream: stream)
    configure_integration(:openai)

    capture_events do |events|
      expect(OpenAI::Resources::Responses.new.stream(model: "gpt-5-mini").text.to_a)
        .to eq(%w[response.created response.completed])

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "gpt-5-mini",
        input_tokens: 75,
        output_tokens: 40,
        total_tokens: 140,
        cache_read_input_tokens: 25,
        hidden_output_tokens: 9,
        stream: true,
        usage_source: :stream_final,
        provider_response_id: "resp_456"
      )
    end
  end

  it "tracks official OpenAI responses.stream_raw calls" do
    stream = stream_class.new([
                                stream_event_class.new(
                                  type: :"response.completed",
                                  response: {
                                    id: "resp_raw", model: "gpt-4o",
                                    usage: { input_tokens: 5, output_tokens: 2, total_tokens: 7 }
                                  }
                                )
                              ])
    install_openai_fakes(response_class.new, stream: stream)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Responses.new.stream_raw(model: "gpt-4o").each { |_event| nil }

      expect(events.first).to include(provider: "openai", model: "gpt-4o", input_tokens: 5, output_tokens: 2)
    end
  end

  it "keeps scoped tags for official OpenAI streams consumed after the call returns" do
    stream = stream_class.new([
                                stream_event_class.new(
                                  type: :"response.completed",
                                  response: {
                                    id: "resp_tagged",
                                    model: "gpt-5-mini",
                                    usage: { input_tokens: 12, output_tokens: 8 }
                                  }
                                )
                              ])
    install_openai_fakes(response_class.new, stream: stream)
    configure_integration(:openai)

    capture_events do |events|
      sdk_stream = LlmCostTracker.with_tags(user_id: 42, feature: "chat") do
        OpenAI::Resources::Responses.new.stream(model: "gpt-5-mini")
      end

      LlmCostTracker.with_tags(user_id: 99, feature: "other") do
        sdk_stream.each { |_event| nil }
      end

      expect(events.first[:tags]).to include(user_id: 42, feature: "chat")
    end
  end

  it "tracks official OpenAI chat.completions.stream_raw calls" do
    stream = stream_class.new([
                                stream_event_class.new(id: "chatcmpl_456", model: "gpt-4o"),
                                stream_event_class.new(
                                  usage: {
                                    prompt_tokens: 30,
                                    prompt_tokens_details: { cached_tokens: 5 },
                                    completion_tokens: 10,
                                    completion_tokens_details: { reasoning_tokens: 3 },
                                    total_tokens: 40
                                  }
                                )
                              ])
    install_openai_fakes(response_class.new, stream: stream)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Chat::Completions.new.stream_raw(model: "gpt-4o", messages: []).each { |_event| nil }

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 25,
        output_tokens: 10,
        total_tokens: 40,
        cache_read_input_tokens: 5,
        hidden_output_tokens: 3,
        stream: true,
        usage_source: :stream_final,
        provider_response_id: "chatcmpl_456"
      )
    end
  end

  it "tracks official OpenAI responses.retrieve_streaming calls" do
    stream = stream_class.new([
                                stream_event_class.new(
                                  type: :"response.completed",
                                  response: {
                                    id: "resp_789",
                                    model: "gpt-5-mini",
                                    usage: { input_tokens: 12, output_tokens: 8 }
                                  }
                                )
                              ])
    install_openai_fakes(response_class.new, stream: stream)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Responses.new.retrieve_streaming("resp_789").each { |_event| nil }

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "gpt-5-mini",
        input_tokens: 12,
        output_tokens: 8,
        stream: true,
        usage_source: :stream_final,
        provider_response_id: "resp_789"
      )
    end
  end

  it "tracks official SDK stream events with nested typed response objects" do
    stream = stream_class.new([
                                stream_event_class.new(
                                  type: :"response.completed",
                                  response: response_class.new(
                                    id: "resp_typed",
                                    model: "gpt-4o",
                                    usage: usage_class.new(input_tokens: 9, output_tokens: 4)
                                  )
                                )
                              ])
    install_openai_fakes(response_class.new, stream: stream)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Responses.new.stream(model: "gpt-4o").each { |_event| nil }

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 9,
        output_tokens: 4,
        stream: true,
        usage_source: :stream_final,
        provider_response_id: "resp_typed"
      )
    end
  end

  it "preserves each without a block for official SDK streams" do
    stream = each_only_stream_class.new([
                                          stream_event_class.new(
                                            type: :"response.completed",
                                            response: {
                                              id: "resp_enum",
                                              model: "gpt-4o",
                                              usage: { input_tokens: 5, output_tokens: 3 }
                                            }
                                          )
                                        ])
    install_openai_fakes(response_class.new, stream: stream)
    configure_integration(:openai)

    capture_events do |events|
      expect(OpenAI::Resources::Responses.new.stream(model: "gpt-4o").each.to_a.map(&:type))
        .to eq([:"response.completed"])

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 5,
        output_tokens: 3,
        stream: true,
        usage_source: :stream_final,
        provider_response_id: "resp_enum"
      )
    end
  end

  it "keeps official SDK stream iteration working when capture cannot read an event" do
    event = LlmCostTrackerIntegrationSpecTypes::BrokenStreamEvent.new
    install_openai_fakes(response_class.new, stream: stream_class.new([event]))
    configure_integration(:openai)

    capture_events do |events|
      expect(OpenAI::Resources::Responses.new.stream(model: "gpt-4o").to_a).to eq([event])

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 0,
        output_tokens: 0,
        stream: true,
        usage_source: :unknown
      )
    end
  end

  it "records errored official SDK streams as unknown usage" do
    stream = failing_stream_class.new(
      [
        stream_event_class.new(
          type: :"response.created",
          response: { id: "resp_error", model: "gpt-4o" }
        )
      ],
      RuntimeError.new("stream failed")
    )
    install_openai_fakes(response_class.new, stream: stream)
    configure_integration(:openai)

    capture_events do |events|
      expect do
        OpenAI::Resources::Responses.new.stream(model: "gpt-4o").each { |_event| nil }
      end.to raise_error(RuntimeError, "stream failed")

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 0,
        output_tokens: 0,
        stream: true,
        usage_source: :unknown,
        provider_response_id: "resp_error"
      )
      expect(events.first[:tags]).to include(stream_errored: true)
    end
  end

  it "tracks official OpenAI embeddings.create calls" do
    embedding_class = LlmCostTrackerIntegrationSpecTypes::EmbeddingResponse
    embedding_usage_class = LlmCostTrackerIntegrationSpecTypes::EmbeddingUsage
    embedding = embedding_class.new(
      model: "text-embedding-3-small",
      usage: embedding_usage_class.new(prompt_tokens: 256, total_tokens: 256)
    )
    install_openai_fakes(response_class.new, embedding: embedding)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Embeddings.new.create(model: "text-embedding-3-small", input: "hello")

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "text-embedding-3-small",
        input_tokens: 256,
        output_tokens: 0,
        usage_source: :sdk_response
      )
      expect(events.first.dig(:cost, :input_cost)).to eq(0.00000512)
      expect(events.first.dig(:cost, :total_cost)).to eq(0.00000512)
    end
  end

  it "tracks official OpenAI images.generate calls with token usage" do
    images_class = LlmCostTrackerIntegrationSpecTypes::ImagesResponse
    images_usage_class = LlmCostTrackerIntegrationSpecTypes::ImagesUsage
    image = images_class.new(
      created: 1_700_000_000,
      usage: images_usage_class.new(input_tokens: 12, output_tokens: 1024, total_tokens: 1036)
    )
    install_openai_fakes(response_class.new, image: image)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Images.new.generate(prompt: "a cat", model: "gpt-image-1", size: "1024x1024")

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "gpt-image-1",
        input_tokens: 12,
        output_tokens: 0,
        image_output_tokens: 1024,
        usage_source: :sdk_response
      )
    end
  end

  it "records OpenAI images.generate calls as zero-token events when usage is missing" do
    images_class = LlmCostTrackerIntegrationSpecTypes::ImagesResponse
    image = images_class.new(created: 1_700_000_000, usage: nil)
    install_openai_fakes(response_class.new, image: image)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Images.new.generate(prompt: "a cat", model: "dall-e-3", size: "1024x1024")

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "dall-e-3",
        input_tokens: 0,
        output_tokens: 0,
        usage_source: :sdk_response
      )
    end
  end

  it "tracks official OpenAI images.edit calls" do
    images_class = LlmCostTrackerIntegrationSpecTypes::ImagesResponse
    images_usage_class = LlmCostTrackerIntegrationSpecTypes::ImagesUsage
    image = images_class.new(
      created: 1_700_000_000,
      usage: images_usage_class.new(input_tokens: 200, output_tokens: 1024, total_tokens: 1224)
    )
    install_openai_fakes(response_class.new, image: image)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Images.new.edit(image: "...", prompt: "make it red", model: "gpt-image-1")

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "gpt-image-1",
        input_tokens: 200,
        output_tokens: 0,
        image_output_tokens: 1024
      )
    end
  end

  it "splits gpt-image-1 input details into text and image input tokens" do
    detailed_usage = Struct.new(
      :input_tokens, :output_tokens, :total_tokens, :input_tokens_details, keyword_init: true
    ) { include SdkFixtureDeepToH }
    detail_struct = Struct.new(:image_tokens, :cached_tokens, keyword_init: true) { include SdkFixtureDeepToH }
    images_class = LlmCostTrackerIntegrationSpecTypes::ImagesResponse
    image = images_class.new(
      created: 1_700_000_000,
      usage: detailed_usage.new(
        input_tokens: 250,
        output_tokens: 1024,
        total_tokens: 1274,
        input_tokens_details: detail_struct.new(image_tokens: 100, cached_tokens: 0)
      )
    )
    install_openai_fakes(response_class.new, image: image)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Images.new.edit(image: "...", prompt: "make it red", model: "gpt-image-1")

      event = events.first
      expect(event).to include(input_tokens: 150, image_input_tokens: 100, image_output_tokens: 1024)
      cost = event.fetch(:cost)
      # 150 text @ $5 + 100 image @ $10 + 1024 image_out @ $40 (per 1M)
      expected_total = (150 * 5.0 + 100 * 10.0 + 1024 * 40.0) / 1_000_000
      expect(cost.fetch(:total_cost)).to be_within(0.000001).of(expected_total)
    end
  end

  it "subtracts cached tokens from text input for gpt-image-1 so cache_read is not double-counted" do
    detailed_usage = Struct.new(
      :input_tokens, :output_tokens, :total_tokens, :input_tokens_details, keyword_init: true
    ) { include SdkFixtureDeepToH }
    detail_struct = Struct.new(:image_tokens, :cached_tokens, keyword_init: true) { include SdkFixtureDeepToH }
    images_class = LlmCostTrackerIntegrationSpecTypes::ImagesResponse
    image = images_class.new(
      created: 1_700_000_000,
      usage: detailed_usage.new(
        input_tokens: 250, output_tokens: 1024, total_tokens: 1274,
        input_tokens_details: detail_struct.new(image_tokens: 100, cached_tokens: 30)
      )
    )
    install_openai_fakes(response_class.new, image: image)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Images.new.edit(image: "...", prompt: "make it red", model: "gpt-image-1")

      event = events.first
      expect(event).to include(
        input_tokens: 120,
        image_input_tokens: 100,
        cache_read_input_tokens: 30,
        image_output_tokens: 1024
      )
    end
  end

  it "splits gpt-image-1.5 output details into text and image output tokens" do
    detailed_usage = Struct.new(
      :input_tokens, :output_tokens, :total_tokens, :output_tokens_details, keyword_init: true
    ) { include SdkFixtureDeepToH }
    output_detail = Struct.new(:image_tokens, :text_tokens, keyword_init: true) { include SdkFixtureDeepToH }
    images_class = LlmCostTrackerIntegrationSpecTypes::ImagesResponse
    image = images_class.new(
      created: 1_700_000_000,
      usage: detailed_usage.new(
        input_tokens: 50,
        output_tokens: 1100,
        total_tokens: 1150,
        output_tokens_details: output_detail.new(image_tokens: 1000, text_tokens: 100)
      )
    )
    install_openai_fakes(response_class.new, image: image)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Images.new.generate(prompt: "a cat", model: "gpt-image-1.5", size: "1024x1024")

      event = events.first
      expect(event).to include(input_tokens: 50, output_tokens: 100, image_output_tokens: 1000)
      cost = event.fetch(:cost)
      # 50 text @ $5 + 100 text out @ $10 + 1000 image_out @ $32 (per 1M)
      expected_total = (50 * 5.0 + 100 * 10.0 + 1000 * 32.0) / 1_000_000
      expect(cost.fetch(:total_cost)).to be_within(0.000001).of(expected_total)
    end
  end

  it "routes Responses.create output to image_output_tokens for gpt-image models when usage omits output details" do
    response = response_class.new(
      id: "resp_img", model: "gpt-image-1",
      usage: usage_class.new(input_tokens: 30, output_tokens: 1568)
    )
    install_openai_fakes(response)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Responses.new.create(model: "gpt-image-1")

      expect(events.first).to include(image_output_tokens: 1568, output_tokens: 0)
    end
  end

  it "recovers text output remainder for gpt-image-1.5 when output_tokens_details only carries image_tokens" do
    detailed_usage = Struct.new(:input_tokens, :output_tokens, :output_tokens_details, keyword_init: true) { include SdkFixtureDeepToH }
    output_detail = Struct.new(:image_tokens, keyword_init: true) { include SdkFixtureDeepToH }
    images_class = LlmCostTrackerIntegrationSpecTypes::ImagesResponse
    image = images_class.new(
      created: 1_700_000_000,
      usage: detailed_usage.new(
        input_tokens: 50, output_tokens: 1100,
        output_tokens_details: output_detail.new(image_tokens: 1000)
      )
    )
    install_openai_fakes(response_class.new, image: image)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Images.new.generate(prompt: "a cat", model: "gpt-image-1.5", size: "1024x1024")

      expect(events.first).to include(output_tokens: 100, image_output_tokens: 1000)
    end
  end

  it "wraps Images#generate_stream_raw through the stream collector" do
    stream = stream_class.new([])
    install_openai_fakes(response_class.new, stream: stream)
    configure_integration(:openai)

    expect { OpenAI::Resources::Images.new.generate_stream_raw(prompt: "a cat", model: "gpt-image-1") }
      .not_to raise_error
  end

  it "wraps Audio::Transcriptions#create_streaming through the stream collector" do
    stream = stream_class.new([])
    install_openai_fakes(response_class.new, stream: stream)
    configure_integration(:openai)

    expect { OpenAI::Resources::Audio::Transcriptions.new.create_streaming(model: "gpt-4o-transcribe", file: "f") }
      .not_to raise_error
  end

  it "tracks official OpenAI images.create_variation calls" do
    images_class = LlmCostTrackerIntegrationSpecTypes::ImagesResponse
    image = images_class.new(created: 1_700_000_000, usage: nil)
    install_openai_fakes(response_class.new, image: image)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Images.new.create_variation(image: "...", model: "dall-e-2")

      expect(events.size).to eq(1)
      expect(events.first).to include(provider: "openai", model: "dall-e-2", input_tokens: 0, output_tokens: 0)
    end
  end

  it "tracks official OpenAI audio.transcriptions.create with token usage" do
    transcription_class = LlmCostTrackerIntegrationSpecTypes::TranscriptionResponse
    tokens_usage_class = LlmCostTrackerIntegrationSpecTypes::TranscriptionTokensUsage
    transcription = transcription_class.new(
      text: "hello",
      usage: tokens_usage_class.new(type: "tokens", input_tokens: 14, output_tokens: 5, total_tokens: 19)
    )
    install_openai_fakes(response_class.new, transcription: transcription)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Audio::Transcriptions.new.create(model: "gpt-4o-transcribe", file: "audio.mp3")

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "gpt-4o-transcribe",
        input_tokens: 14,
        output_tokens: 5,
        audio_input_tokens: 0,
        usage_source: :sdk_response
      )
    end
  end

  it "splits audio input tokens out of the input_tokens bucket on gpt-4o-transcribe" do
    transcription_class = LlmCostTrackerIntegrationSpecTypes::TranscriptionResponse
    tokens_usage_class = LlmCostTrackerIntegrationSpecTypes::TranscriptionTokensUsage
    details_class = LlmCostTrackerIntegrationSpecTypes::TranscriptionInputTokenDetails
    transcription = transcription_class.new(
      text: "hello",
      usage: tokens_usage_class.new(
        type: "tokens",
        input_tokens: 200,
        output_tokens: 18,
        total_tokens: 218,
        input_token_details: details_class.new(audio_tokens: 150, text_tokens: 50)
      )
    )
    install_openai_fakes(response_class.new, transcription: transcription)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Audio::Transcriptions.new.create(model: "gpt-4o-transcribe", file: "audio.mp3")

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "gpt-4o-transcribe",
        input_tokens: 50,
        audio_input_tokens: 150,
        output_tokens: 18,
        usage_source: :sdk_response
      )
      cost = events.first.fetch(:cost)
      expect(cost).to include(audio_input_cost: 0.0009, input_cost: 0.000125, output_cost: 0.00018)
    end
  end

  it "records OpenAI audio.transcriptions.create as zero-token when usage uses the duration variant" do
    transcription_class = LlmCostTrackerIntegrationSpecTypes::TranscriptionResponse
    duration_usage_class = LlmCostTrackerIntegrationSpecTypes::TranscriptionDurationUsage
    transcription = transcription_class.new(
      text: "hello",
      usage: duration_usage_class.new(type: "duration", seconds: 12.5)
    )
    install_openai_fakes(response_class.new, transcription: transcription)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Audio::Transcriptions.new.create(model: "whisper-1", file: "audio.mp3")

      expect(events.size).to eq(1)
      expect(events.first).to include(provider: "openai", model: "whisper-1", input_tokens: 0, output_tokens: 0)
    end
  end

  it "records OpenAI audio.translations.create as a zero-token whisper visibility event" do
    transcription_class = LlmCostTrackerIntegrationSpecTypes::TranscriptionResponse
    duration_usage_class = LlmCostTrackerIntegrationSpecTypes::TranscriptionDurationUsage
    transcription = transcription_class.new(
      text: "hello",
      usage: duration_usage_class.new(type: "duration", seconds: 7.0)
    )
    install_openai_fakes(response_class.new, transcription: transcription)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Audio::Translations.new.create(model: "whisper-1", file: "audio.mp3")

      expect(events.size).to eq(1)
      expect(events.first).to include(provider: "openai", model: "whisper-1", input_tokens: 0, output_tokens: 0)
    end
  end

  it "records OpenAI audio.speech.create calls and prices the input characters at the per-model rate" do
    install_openai_fakes(response_class.new, speech: "binary-audio-bytes")
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Audio::Speech.new.create(model: "tts-1", input: "hello world", voice: "alloy")

      expect(events.size).to eq(1)
      event = events.first
      expect(event).to include(provider: "openai", model: "tts-1", input_tokens: 0, output_tokens: 0)
      tts_line = event.fetch(:line_items).find { |li| li.fetch(:kind) == :text_to_speech_character }
      expect(tts_line.fetch(:quantity)).to eq("11.0")
      expect(tts_line.fetch(:cost_status)).to eq(LlmCostTracker::Billing::CostStatus::COMPLETE)
      # tts-1: $15 per 1M chars; 11 chars = 0.000165
      expect(BigDecimal(tts_line.fetch(:cost))).to eq(BigDecimal("0.000165"))
    end
  end

  it "skips TTS line item when the speech request has no string input" do
    install_openai_fakes(response_class.new, speech: "binary-audio-bytes")
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Audio::Speech.new.create(model: "tts-1", input: nil, voice: "alloy")

      tts_line = events.first.fetch(:line_items).find { |li| li.fetch(:kind) == :text_to_speech_character }
      expect(tts_line).to be_nil
    end
  end

  it "skips TTS line item for non-character-billed models like gpt-4o-mini-tts" do
    install_openai_fakes(response_class.new, speech: "binary-audio-bytes")
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Audio::Speech.new.create(model: "gpt-4o-mini-tts", input: "hello", voice: "alloy")

      tts_line = events.first.fetch(:line_items).find { |li| li.fetch(:kind) == :text_to_speech_character }
      expect(tts_line).to be_nil
    end
  end

  it "records OpenAI moderations.create calls as zero-token visibility events" do
    moderation_class = LlmCostTrackerIntegrationSpecTypes::ModerationResponse
    moderation = moderation_class.new(id: "modr-123", model: "omni-moderation-latest", results: [])
    install_openai_fakes(response_class.new, moderation: moderation)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Moderations.new.create(model: "omni-moderation-latest", input: "hello")

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "omni-moderation-latest",
        input_tokens: 0,
        output_tokens: 0,
        provider_response_id: "modr-123"
      )
    end
  end

  it "tracks official OpenAI chat.completions.stream calls" do
    event = stream_event_class.new(
      type: "chat.completion.chunk",
      id: "chatcmpl_stream_1",
      model: "gpt-4o",
      usage: usage_class.new(input_tokens: 80, output_tokens: 30)
    )
    stream = stream_class.new([event])
    install_openai_fakes(response_class.new, stream: stream)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Chat::Completions.new.stream(model: "gpt-4o", messages: []).each { |_event| nil }

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 80,
        output_tokens: 30,
        stream: true,
        usage_source: :stream_final,
        provider_response_id: "chatcmpl_stream_1"
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
        cache_creation_input_tokens: 30,
        cache_creation: {
          ephemeral_5m_input_tokens: 20,
          ephemeral_1h_input_tokens: 10
        },
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
        cache_write_input_tokens: 20,
        cache_write_extended_input_tokens: 10,
        hidden_output_tokens: 6,
        usage_source: :sdk_response,
        provider_response_id: "msg_123"
      )
      expect(events.first.dig(:cost, :cache_write_input_cost)).to eq(0.000075)
      expect(events.first.dig(:cost, :cache_write_extended_input_cost)).to eq(0.00006)
    end
  end

  it "treats Anthropic Priority Tier as standard pricing (throughput tier, no per-token surcharge)" do
    message = response_class.new(
      id: "msg_123",
      model: "claude-sonnet-4-6",
      usage: usage_class.new(
        input_tokens: 120,
        output_tokens: 35,
        service_tier: "priority"
      )
    )
    install_anthropic_fakes(message)
    configure_integration(:anthropic)

    capture_events do |events|
      Anthropic::Resources::Messages.new.create(model: "claude-sonnet-4-6")

      expect(events.size).to eq(1)
      expect(events.first[:pricing_mode]).to be_nil
    end
  end

  it "captures the Anthropic batch service tier as a pricing mode" do
    message = response_class.new(
      id: "msg_batch",
      model: "claude-sonnet-4-6",
      usage: usage_class.new(
        input_tokens: 120,
        output_tokens: 35,
        service_tier: "batch"
      )
    )
    install_anthropic_fakes(message)
    configure_integration(:anthropic)

    capture_events do |events|
      Anthropic::Resources::Messages.new.create(model: "claude-sonnet-4-6")

      expect(events.size).to eq(1)
      expect(events.first[:pricing_mode]).to eq(:batch)
    end
  end

  it "captures Anthropic server tool usage from the official SDK as service line items" do
    message = response_class.new(
      id: "msg_123",
      model: "claude-sonnet-4-6",
      usage: usage_class.new(
        input_tokens: 200, output_tokens: 80,
        server_tool_use: LlmCostTrackerIntegrationSpecTypes::ServerToolUse.new(
          web_search_requests: 2, code_execution_requests: 1
        )
      )
    )
    install_anthropic_fakes(message)
    configure_integration(:anthropic)

    capture_events do |events|
      Anthropic::Resources::Messages.new.create(model: "claude-sonnet-4-6")

      kinds = events.first[:line_items].reject { |item| item[:unit] == :token }.map { |item| item[:kind] }
      expect(kinds).to eq(%i[web_search_request code_execution_request])
    end
  end

  it "captures OpenAI hosted tool output items from the official SDK as service line items" do
    response = response_class.new(
      id: "resp_123",
      model: "gpt-5-mini",
      usage: usage_class.new(prompt_tokens: 100, completion_tokens: 30),
      output: [
        LlmCostTrackerIntegrationSpecTypes::OutputItem.new(
          type: "web_search_call", id: "ws_123", status: "completed",
          action: LlmCostTrackerIntegrationSpecTypes::OutputAction.new(type: "search")
        ),
        LlmCostTrackerIntegrationSpecTypes::OutputItem.new(
          type: "file_search_call", id: "fs_123", status: "completed"
        )
      ]
    )
    install_openai_fakes(response)
    configure_integration(:openai)

    capture_events do |events|
      OpenAI::Resources::Responses.new.create(model: "gpt-5-mini", input: "hi")

      kinds = events.first[:line_items].reject { |item| item[:unit] == :token }.map { |item| item[:kind] }
      expect(kinds).to eq(%i[web_search_request file_search_call])
    end
  end

  it "captures official Anthropic batch data residency pricing modes" do
    message = response_class.new(
      id: "msg_123",
      model: "claude-sonnet-4-6",
      usage: usage_class.new(
        input_tokens: 1_000_000,
        output_tokens: 1_000_000,
        service_tier: "batch",
        inference_geo: "us"
      )
    )
    install_anthropic_fakes(message)
    configure_integration(:anthropic)

    capture_events do |events|
      Anthropic::Resources::Messages.new.create(model: "claude-sonnet-4-6", service_tier: "batch", inference_geo: "us")

      expect(events.size).to eq(1)
      expect(events.first[:pricing_mode]).to eq(:batch_data_residency)
      expect(events.first.dig(:cost, :total_cost)).to be_positive
    end
  end

  it "captures official Anthropic fast data residency pricing modes" do
    message = response_class.new(
      id: "msg_123",
      model: "claude-opus-4-6",
      usage: usage_class.new(
        input_tokens: 120,
        output_tokens: 35,
        speed: "fast",
        inference_geo: "us"
      )
    )
    install_anthropic_fakes(message)
    configure_integration(:anthropic)

    capture_events do |events|
      Anthropic::Resources::Messages.new.create(model: "claude-opus-4-6", speed: "fast", inference_geo: "us")

      expect(events.size).to eq(1)
      expect(events.first[:pricing_mode]).to eq(:fast_data_residency)
      expect(events.first.dig(:cost, :input_cost)).to eq(0.00396)
      expect(events.first.dig(:cost, :output_cost)).to eq(0.005775)
    end
  end

  it "tracks official Anthropic messages.stream calls" do
    stream = stream_class.new([
                                stream_event_class.new(
                                  type: :message_start,
                                  message: {
                                    id: "msg_456",
                                    model: "claude-sonnet-4-6",
                                    usage: {
                                      input_tokens: 120,
                                      output_tokens: 1,
                                      cache_read_input_tokens: 40,
                                      cache_creation_input_tokens: 30,
                                      cache_creation: {
                                        ephemeral_5m_input_tokens: 20,
                                        ephemeral_1h_input_tokens: 10
                                      }
                                    }
                                  }
                                ),
                                stream_event_class.new(
                                  type: :message_delta,
                                  usage: { output_tokens: 64 }
                                )
                              ])
    install_anthropic_fakes(response_class.new, stream: stream)
    configure_integration(:anthropic)

    capture_events do |events|
      Anthropic::Resources::Messages.new.stream(
        model: "claude-sonnet-4-6",
        max_tokens: 1024,
        messages: []
      ).each { |_event| nil }

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "anthropic",
        model: "claude-sonnet-4-6",
        input_tokens: 120,
        output_tokens: 64,
        total_tokens: 254,
        cache_read_input_tokens: 40,
        cache_write_input_tokens: 20,
        cache_write_extended_input_tokens: 10,
        stream: true,
        usage_source: :stream_final,
        provider_response_id: "msg_456"
      )
    end
  end

  it "tracks official Anthropic messages.stream_raw calls" do
    stream = stream_class.new([
                                stream_event_class.new(
                                  type: :message_start,
                                  message: {
                                    id: "msg_789",
                                    model: "claude-sonnet-4-6",
                                    usage: { input_tokens: 30, output_tokens: 0 }
                                  }
                                ),
                                stream_event_class.new(type: :message_delta, usage: { output_tokens: 14 })
                              ])
    install_anthropic_fakes(response_class.new, stream: stream)
    configure_integration(:anthropic)

    capture_events do |events|
      Anthropic::Resources::Messages.new.stream_raw(
        model: "claude-sonnet-4-6",
        max_tokens: 1024,
        messages: []
      ).each { |_event| nil }

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "anthropic",
        model: "claude-sonnet-4-6",
        input_tokens: 30,
        output_tokens: 14,
        stream: true,
        usage_source: :stream_final,
        provider_response_id: "msg_789"
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

  it "treats Anthropic service_tier=priority as standard pricing for RubyLLM completions" do
    response = LlmCostTrackerIntegrationSpecTypes::RubyLlmResponse.new(
      id: "msg_pri",
      model_id: "claude-sonnet-4-6",
      input_tokens: 100,
      output_tokens: 30,
      service_tier: "priority"
    )
    model = LlmCostTrackerIntegrationSpecTypes::RubyLlmModel.new(id: "claude-sonnet-4-6")
    install_ruby_llm_fakes(response)
    configure_integration(:ruby_llm)

    capture_events do |events|
      RubyLLM::Provider.new(provider: "anthropic")
                       .complete([], model: model, tools: {}, temperature: nil) { |_| nil }

      expect(events.first[:pricing_mode]).to be_nil
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
        usage_source: :sdk_response,
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
        usage_source: :sdk_response
      )
    end
  end

  it "tracks RubyLLM transcriptions through the provider contract" do
    response = LlmCostTrackerIntegrationSpecTypes::RubyLlmResponse.new(
      id: "audio_resp_123",
      input_tokens: 12,
      output_tokens: 3,
      reasoning_tokens: 2
    )
    install_ruby_llm_fakes(response)
    configure_integration(:ruby_llm)

    capture_events do |events|
      returned = RubyLLM::Provider.new.transcribe("audio.wav", model: :whisper_one)

      expect(returned).to be(response)
      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "whisper_one",
        input_tokens: 12,
        output_tokens: 3,
        hidden_output_tokens: 2,
        stream: false,
        usage_source: :sdk_response,
        provider_response_id: "audio_resp_123"
      )
    end
  end

  it "tracks RubyLLM image generation through the provider contract" do
    image = LlmCostTrackerIntegrationSpecTypes::RubyLlmImage.new(
      model_id: "gpt-image-1",
      usage: { input_tokens: 25, output_tokens: 0 },
      provider_response_id: "img_resp_123"
    )
    install_ruby_llm_fakes(image, image: image)
    configure_integration(:ruby_llm)

    capture_events do |events|
      returned = RubyLLM::Provider.new.paint("a cat", model: "gpt-image-1", size: "1024x1024")

      expect(returned).to be(image)
      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "gpt-image-1",
        input_tokens: 25,
        output_tokens: 0,
        usage_source: :sdk_response,
        provider_response_id: "img_resp_123"
      )
    end
  end

  it "routes RubyLLM image output tokens to image_output_tokens for image models" do
    image = LlmCostTrackerIntegrationSpecTypes::RubyLlmImage.new(
      model_id: "gpt-image-1.5",
      usage: {
        input_tokens: 50,
        output_tokens: 100,
        input_tokens_details: { image_tokens: 30 },
        output_tokens_details: { image_tokens: 80 }
      },
      provider_response_id: "img_resp_split"
    )
    install_ruby_llm_fakes(image, image: image)
    configure_integration(:ruby_llm)

    capture_events do |events|
      RubyLLM::Provider.new.paint("a cat", model: "gpt-image-1.5", size: "1024x1024")

      expect(events.first.dig(:token_usage, :input_tokens)).to eq(20)
      expect(events.first.dig(:token_usage, :image_input_tokens)).to eq(30)
      expect(events.first.dig(:token_usage, :output_tokens)).to eq(20)
      expect(events.first.dig(:token_usage, :image_output_tokens)).to eq(80)
    end
  end

  it "records RubyLLM image generation as a zero-token event when usage hash is missing" do
    image = LlmCostTrackerIntegrationSpecTypes::RubyLlmImage.new(
      model_id: "dall-e-3",
      usage: nil,
      provider_response_id: "img_resp_456"
    )
    install_ruby_llm_fakes(image, image: image)
    configure_integration(:ruby_llm)

    capture_events do |events|
      RubyLLM::Provider.new.paint("a dog", model: "dall-e-3", size: "512x512")

      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "dall-e-3",
        input_tokens: 0,
        output_tokens: 0
      )
    end
  end

  it "tracks RubyLLM moderation calls as zero-token events" do
    moderation = LlmCostTrackerIntegrationSpecTypes::RubyLlmModeration.new(
      id: "mod_resp_123",
      model_id: "omni-moderation-latest"
    )
    install_ruby_llm_fakes(moderation, moderation: moderation)
    configure_integration(:ruby_llm)

    capture_events do |events|
      returned = RubyLLM::Provider.new.moderate("input", model: "omni-moderation-latest")

      expect(returned).to be(moderation)
      expect(events.size).to eq(1)
      expect(events.first).to include(
        provider: "openai",
        model: "omni-moderation-latest",
        input_tokens: 0,
        output_tokens: 0,
        usage_source: :sdk_response
      )
    end
  end

  it "warns when :ruby_llm and a Faraday-parser integration are enabled together" do
    allow(LlmCostTracker::Logging).to receive(:warn)

    LlmCostTracker::Integrations.warn_double_instrumentation(%i[ruby_llm openai])

    expect(LlmCostTracker::Logging).to have_received(:warn).with(/ruby_llm.*together with.*openai/)
  end

  it "does not warn when only :ruby_llm is enabled" do
    allow(LlmCostTracker::Logging).to receive(:warn)

    LlmCostTracker::Integrations.warn_double_instrumentation(%i[ruby_llm])

    expect(LlmCostTracker::Logging).not_to have_received(:warn)
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
        usage_source: :sdk_response
      )
    end
  end

  it "reports installed RubyLLM integration checks after patching" do
    install_ruby_llm_fakes(LlmCostTrackerIntegrationSpecTypes::RubyLlmResponse.new(input_tokens: 1, output_tokens: 1))
    configure_integration(:ruby_llm)

    check = LlmCostTracker::Integrations.checks([:ruby_llm]).first

    expect(check.status).to eq(:ok)
    expect(check.message).to eq("ruby_llm integration installed")
  end

  it "reports available but uninstalled integrations" do
    install_ruby_llm_fakes(LlmCostTrackerIntegrationSpecTypes::RubyLlmResponse.new(input_tokens: 1, output_tokens: 1))

    check = LlmCostTracker::Integrations.checks([:ruby_llm]).first

    expect(check.status).to eq(:warn)
    expect(check.message).to eq("ruby_llm integration is enabled but not installed")
  end

  it "raises when an enabled integration cannot satisfy its install contract" do
    stub_const("RubyLLM", Module.new)
    stub_const("RubyLLM::VERSION", "1.13.0")
    allow(Gem.loaded_specs).to receive(:[]).and_call_original
    allow(Gem.loaded_specs).to receive(:[]).with("ruby_llm").and_return(nil)

    expect do
      configure_integration(:ruby_llm)
    end.to raise_error(
      LlmCostTracker::Error,
      /ruby_llm integration cannot be installed: ruby_llm >= 1\.14\.1 is required, detected 1\.13\.0/
    )
  end

  it "reports incompatible integrations with invalid SDK version constants" do
    stub_const("RubyLLM", Module.new)
    stub_const("RubyLLM::VERSION", "not-a-version")
    allow(Gem.loaded_specs).to receive(:[]).and_call_original
    allow(Gem.loaded_specs).to receive(:[]).with("ruby_llm").and_return(nil)

    check = LlmCostTracker::Integrations.checks([:ruby_llm]).first

    expect(check.status).to eq(:warn)
    expect(check.message).to include("ruby_llm >= 1.14.1 is required, but ruby_llm is not loaded")
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
    allow(Gem.loaded_specs).to receive(:[]).and_call_original
    allow(Gem.loaded_specs).to receive(:[]).with("anthropic").and_return(nil)
    hide_const("Anthropic")

    expect(LlmCostTracker::Integrations.checks([:anthropic]).first.message)
      .to include("anthropic integration cannot be installed")
  end

  it "expands the all instrumentation alias" do
    install_openai_fakes(response_class.new(usage: usage_class.new(input_tokens: 1, output_tokens: 1)))
    install_anthropic_fakes(response_class.new(usage: usage_class.new(input_tokens: 1, output_tokens: 1)))
    install_ruby_llm_fakes(LlmCostTrackerIntegrationSpecTypes::RubyLlmResponse.new(input_tokens: 1, output_tokens: 1))

    LlmCostTracker.configure { |config| config.instrument :all }

    expect(LlmCostTracker.configuration.instrumented_integrations).to contain_exactly(:openai, :anthropic, :ruby_llm)
    expect { LlmCostTracker.configuration.instrumented_integrations.add(:gemini) }.to raise_error(FrozenError)
  end

  it "rejects unknown integrations" do
    expect do
      LlmCostTracker.configure { |config| config.instrument :gemini }
    end.to raise_error(LlmCostTracker::Error, /Unknown integration: :gemini/)
  end

  it "rejects unknown integration fetches" do
    expect do
      LlmCostTracker::Integrations.fetch(:gemini)
    end.to raise_error(LlmCostTracker::Error, /Unknown integration: :gemini/)
  end
end
