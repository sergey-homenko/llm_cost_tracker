# frozen_string_literal: true

require "spec_helper"
require "openai"
require "stringio"
require "weakref"

RSpec.describe LlmCostTracker::Integrations::Openai do
  before { configure_sdk_integration(:openai) }

  let(:client) { OpenAI::Client.new(api_key: "test-key") }
  let(:audio_io) { StringIO.new("RIFF").tap { |io| io.set_encoding(Encoding::BINARY) } }
  let(:image_io) { StringIO.new("\x89PNG").tap { |io| io.set_encoding(Encoding::BINARY) } }
  let(:logprobs) do
    Array.new(500) do |index|
      token = " word#{index}"
      top = Array.new(20) { |rank| { token: "#{token}#{rank}", logprob: -1.0 - rank, bytes: "#{token}#{rank}".bytes } }
      { token: token, logprob: -0.5, bytes: token.bytes, top_logprobs: top }
    end
  end

  describe "responses.create" do
    it "records token usage with cached and reasoning breakdowns" do
      stub_sdk_json(:post, "https://api.openai.com/v1/responses",
                    provider: :openai, fixture: "responses_create.json")

      capture_sdk_events do |events|
        response = client.responses.create(model: "gpt-4o", input: "hi")

        expect(response).to be_a(OpenAI::Models::Responses::Response)
        expect(events.first).to include(
          provider: "openai",
          model: "gpt-4o",
          input_tokens: 40,
          output_tokens: 25,
          cache_read_input_tokens: 10,
          hidden_output_tokens: 5,
          usage_source: "sdk_response",
          provider_response_id: "resp_abc"
        )
      end
    end

    it "warns and records nothing for a queued background response without usage" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/responses").to_return(
        status: 200,
        body: { id: "resp_bg", object: "response", model: "o3-pro", status: "queued", background: true,
                created_at: 1, output: [], usage: nil }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
      allow(LlmCostTracker::Logging).to receive(:warn)

      capture_sdk_events do |events|
        client.responses.create(model: "o3-pro", input: "hi", background: true)
        expect(events).to be_empty
      end
      expect(LlmCostTracker::Logging).to have_received(:warn).with("OpenAI response resp_bg has no usage; not recorded")
    end
  end

  describe "chat.completions.create" do
    it "records token usage with prompt/completion field mapping and cached split" do
      stub_sdk_json(:post, "https://api.openai.com/v1/chat/completions",
                    provider: :openai, fixture: "chat_completions_create.json")

      capture_sdk_events do |events|
        response = client.chat.completions.create(
          model: "gpt-4o",
          messages: [{ role: "user", content: "hi" }]
        )

        expect(response).to be_a(OpenAI::Models::Chat::ChatCompletion)
        expect(events.first).to include(
          provider: "openai",
          model: "gpt-4o",
          input_tokens: 40,
          output_tokens: 25,
          cache_read_input_tokens: 10,
          usage_source: "sdk_response",
          provider_response_id: "chatcmpl_xyz"
        )
      end
    end

    it "splits audio input/output tokens from text for an audio model" do
      stub_sdk_json(:post, "https://api.openai.com/v1/chat/completions",
                    provider: :openai, fixture: "chat_completions_with_audio.json")

      capture_sdk_events do |events|
        client.chat.completions.create(
          model: "gpt-4o-audio-preview",
          messages: [{ role: "user", content: "hi" }]
        )
        expect(events.first).to include(
          audio_input_tokens: 15,
          audio_output_tokens: 25,
          input_tokens: 15,
          output_tokens: 15
        )
      end
    end
  end

  describe "embeddings.create" do
    it "records token usage for embeddings" do
      stub_sdk_json(:post, "https://api.openai.com/v1/embeddings",
                    provider: :openai, fixture: "embeddings_create.json")

      capture_sdk_events do |events|
        client.embeddings.create(model: "text-embedding-3-large", input: "hi")

        expect(events.first).to include(
          provider: "openai",
          model: "text-embedding-3-large",
          input_tokens: 30,
          output_tokens: 0,
          usage_source: "sdk_response"
        )
      end
    end
  end

  describe "images.generate" do
    it "records image tokens split from text input on real SDK response" do
      stub_sdk_json(:post, "https://api.openai.com/v1/images/generations",
                    provider: :openai, fixture: "images_generate.json")

      capture_sdk_events do |events|
        client.images.generate(prompt: "a cat", model: "gpt-image-1")

        expect(events.first).to include(
          provider: "openai",
          model: "gpt-image-1",
          input_tokens: 10,
          image_input_tokens: 15,
          output_tokens: 0,
          usage_source: "sdk_response"
        )
      end
    end
  end

  describe "images.generate with gpt-image-2.5-sunburst" do
    it "prices text input and image output at the published GPT Image 2.5 rates" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/images/generations").to_return(
        status: 200,
        body: { created: 1, data: [{ b64_json: "iVBORw0KGgo=" }],
                usage: { input_tokens: 50, input_tokens_details: { text_tokens: 50, image_tokens: 0 },
                         output_tokens: 1056, total_tokens: 1106 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        client.images.generate(model: "gpt-image-2.5-sunburst", prompt: "a cat")

        expect(events.first).to include(cost_status: "complete")
        expect(BigDecimal(events.first.dig(:cost, :total).to_s)).to eq(BigDecimal("0.03193"))
      end
    end
  end

  describe "images.edit" do
    it "records image tokens through the same recorder as images.generate" do
      stub_sdk_json(:post, "https://api.openai.com/v1/images/edits",
                    provider: :openai, fixture: "images_generate.json")

      capture_sdk_events do |events|
        client.images.edit(image: image_io, prompt: "make it blue", model: "gpt-image-1")

        expect(events.first).to include(
          provider: "openai",
          model: "gpt-image-1",
          input_tokens: 10,
          image_input_tokens: 15,
          output_tokens: 0,
          usage_source: "sdk_response"
        )
      end
    end
  end

  describe "images.create_variation" do
    it "records token usage from the variations endpoint" do
      stub_sdk_json(:post, "https://api.openai.com/v1/images/variations",
                    provider: :openai, fixture: "images_generate.json")

      capture_sdk_events do |events|
        client.images.create_variation(image: image_io, model: "dall-e-2")

        expect(events.first).to include(
          provider: "openai",
          model: "dall-e-2",
          input_tokens: 10,
          image_input_tokens: 15,
          output_tokens: 0,
          usage_source: "sdk_response"
        )
      end
    end
  end

  describe "audio.transcriptions.create" do
    it "splits audio tokens out of input bucket on real SDK transcription" do
      stub_sdk_json(:post, "https://api.openai.com/v1/audio/transcriptions",
                    provider: :openai, fixture: "transcription_create.json")

      capture_sdk_events do |events|
        client.audio.transcriptions.create(file: audio_io, model: "gpt-4o-transcribe")

        expect(events.first).to include(
          provider: "openai",
          model: "gpt-4o-transcribe",
          input_tokens: 4,
          audio_input_tokens: 8,
          output_tokens: 3,
          usage_source: "sdk_response"
        )
      end
    end

    it "prices whisper-1 duration usage at $0.006 per started minute" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/transcriptions").to_return(
        status: 200,
        body: { text: "hello", usage: { type: "duration", seconds: 125.5 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        client.audio.transcriptions.create(file: audio_io, model: "whisper-1")

        line = events.first[:line_items].find { |item| item[:kind] == "transcription_minute" }
        expect(line[:quantity].to_i).to eq(3)
        expect(events.first).to include(cost_status: "complete")
        expect(BigDecimal(events.first.dig(:cost, :total).to_s)).to eq(BigDecimal("0.018"))
      end
    end
  end

  describe "audio.translations.create" do
    it "records a whisper-1 translation as unknown, not free, because translations carry no usage" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/translations").to_return(
        status: 200, body: { text: "hello" }.to_json, headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        client.audio.translations.create(file: audio_io, model: "whisper-1")

        expect(events.first).to include(provider: "openai", model: "whisper-1", usage_source: "unknown",
                                        cost_status: "unknown")
      end
    end
  end

  describe "audio.speech.create" do
    before do
      WebMock.stub_request(:post, "https://api.openai.com/v1/audio/speech")
             .to_return(status: 200, body: "binary-audio", headers: { "Content-Type" => "audio/mpeg" })
    end

    it "emits a text_to_speech_character line item priced by input length for tts-1" do
      capture_sdk_events do |events|
        client.audio.speech.create(model: "tts-1", voice: "alloy", input: "hello world")

        line_item = events.first[:line_items].find { |item| item[:kind] == "text_to_speech_character" }
        expect(line_item[:quantity].to_i).to eq("hello world".length)
      end
    end

    it "does not emit a line item for non-character-billed TTS models like gpt-4o-mini-tts" do
      capture_sdk_events do |events|
        client.audio.speech.create(model: "gpt-4o-mini-tts", voice: "alloy", input: "hello world")

        kinds = events.first[:line_items].map { |item| item[:kind] }
        expect(kinds).not_to include("text_to_speech_character")
      end
    end
  end

  describe "batches.retrieve" do
    before do
      LlmCostTracker::Integrations::Openai::BatchCapture.instance_variable_set(:@dedup, nil)
    end

    let(:jsonl_body) do
      [
        { id: "batch_req_a", custom_id: "u1",
          response: { status_code: 200, body: {
            id: "chatcmpl_b1", object: "chat.completion", model: "gpt-4o",
            choices: [{ index: 0, message: { role: "assistant", content: "hi" }, finish_reason: "stop" }],
            usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
          } } },
        { id: "batch_req_b", custom_id: "u2", error: { code: "rate_limit", message: "slow down" }, response: nil }
      ].map(&:to_json).join("\n")
    end

    def stub_batch(status: "completed", host: "api.openai.com", model: nil, body: jsonl_body)
      WebMock.stub_request(:get, "https://#{host}/v1/batches/batch_done").to_return(
        status: 200,
        body: { id: "batch_done", object: "batch", status: status, model: model,
                input_file_id: "file_in", output_file_id: "file_out",
                endpoint: "/v1/chat/completions" }.compact.to_json,
        headers: { "Content-Type" => "application/json" }
      )
      WebMock.stub_request(:get, "https://#{host}/v1/files/file_out/content").to_return(
        status: 200, body: body,
        headers: { "Content-Type" => "application/binary" }
      )
    end

    def batch_line(body)
      { id: "batch_req_x", custom_id: "u1", response: { status_code: 200, body: body } }.to_json
    end

    it "captures per-request usage from a completed batch and skips errored entries" do
      stub_batch

      capture_sdk_events do |events|
        client.batches.retrieve("batch_done")

        expect(events.size).to eq(1)
        expect(events.first).to include(
          provider: "openai",
          model: "gpt-4o",
          pricing_mode: "batch",
          provider_response_id: "chatcmpl_b1",
          usage_source: "sdk_batch_result"
        )
      end
    end

    %w[expired cancelled].each do |status|
      it "captures the billed results in the output file of a batch that ended #{status}" do
        stub_batch(status: status)

        capture_sdk_events do |events|
          client.batches.retrieve("batch_done")

          expect(events.map { |event| event[:provider_response_id] }).to eq(["chatcmpl_b1"])
        end
      end
    end

    it "waits for a cancelling batch to reach cancelled before downloading its output file" do
      stub_batch(status: "cancelling")

      capture_sdk_events do |events|
        client.batches.retrieve("batch_done")

        expect(events).to be_empty
        expect(WebMock).not_to have_requested(:get, "https://api.openai.com/v1/files/file_out/content")
      end
    end

    it "skips a batch result whose provider_response_id already lives in the ledger so a second-process retrieve is a no-op" do
      stub_batch
      allow(LlmCostTracker::Call).to receive(:already_recorded?)
        .with(provider: "openai", provider_response_id: "chatcmpl_b1")
        .and_return(true)

      capture_sdk_events do |events|
        client.batches.retrieve("batch_done")

        expect(events).to be_empty
      end
    end

    it "keys an embeddings result without a body id by its batch_req id so a second-process retrieve is a no-op" do
      stub_batch(body: batch_line(JSON.parse(sdk_fixture(:openai, "embeddings_create.json"))))

      capture_sdk_events do |events|
        client.batches.retrieve("batch_done")
        expect(events.map { |event| event[:provider_response_id] }).to eq(["batch_req_x"])

        LlmCostTracker::Integrations::Openai::BatchCapture.instance_variable_set(:@dedup, nil)
        allow(LlmCostTracker::Call).to receive(:already_recorded?)
          .with(provider: "openai", provider_response_id: "batch_req_x")
          .and_return(true)
        client.batches.retrieve("batch_done")
        expect(events.size).to eq(1)
      end
    end

    it "prices an images batch result with the batch model and batch image rates" do
      body = { created: 1, data: [],
               usage: { input_tokens: 50, output_tokens: 1056, total_tokens: 1106,
                        input_tokens_details: { text_tokens: 50, image_tokens: 0 } } }
      stub_batch(model: "gpt-image-1", body: batch_line(body))

      capture_sdk_events do |events|
        client.batches.retrieve("batch_done")

        expect(events.first).to include(model: "gpt-image-1", pricing_mode: "batch",
                                        input_tokens: 50, output_tokens: 0, image_output_tokens: 1056)
        expect(events.first.dig(:cost, :total)).to eq("0.021245")
      end
    end

    { "eu.api.openai.com" => ["batch_data_residency", "0.3784"],
      "au.api.openai.com" => ["batch", "0.344"] }.each do |host, (mode, total)|
      it "prices a gpt-5.4 batch result fetched through #{host} as #{mode}" do
        body = { id: "chatcmpl_dr", object: "chat.completion", model: "gpt-5.4-2026-03-05", choices: [],
                 usage: { prompt_tokens: 200_000, completion_tokens: 20_000, total_tokens: 220_000,
                          prompt_tokens_details: { cached_tokens: 50_000 } } }
        stub_batch(host: host, body: batch_line(body))
        regional_client = OpenAI::Client.new(api_key: "test-key", base_url: "https://#{host}/v1")

        capture_sdk_events do |events|
          regional_client.batches.retrieve("batch_done")

          expect(events.first).to include(pricing_mode: mode)
          expect(events.first.dig(:cost, :total)).to eq(total)
        end
      end
    end
  end

  describe "moderations.create" do
    it "records moderation as a zero-token event from real SDK response" do
      stub_sdk_json(:post, "https://api.openai.com/v1/moderations",
                    provider: :openai, fixture: "moderations_create.json")

      capture_sdk_events do |events|
        client.moderations.create(input: "hello")

        expect(events.first).to include(
          provider: "openai",
          model: "omni-moderation-latest",
          input_tokens: 0,
          output_tokens: 0,
          usage_source: "sdk_response",
          provider_response_id: "modr_abc"
        )
      end
    end
  end

  describe "chat.completions streaming" do
    let(:chat_sse_body) do
      <<~SSE
        data: {"id":"chatcmpl_s","object":"chat.completion.chunk","model":"gpt-4o","choices":[{"index":0,"delta":{"content":"hi"}}]}

        data: {"id":"chatcmpl_s","object":"chat.completion.chunk","model":"gpt-4o","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}

        data: [DONE]

      SSE
    end

    it "records token usage from chat.completions.stream" do
      stub_sdk_sse(:post, "https://api.openai.com/v1/chat/completions", body: chat_sse_body)

      capture_sdk_events do |events|
        stream = client.chat.completions.stream(
          model: "gpt-4o", messages: [{ role: "user", content: "hi" }]
        )
        stream.each { |_| }

        expect(events.first).to include(
          provider: "openai", model: "gpt-4o", stream: true,
          input_tokens: 10, output_tokens: 5,
          usage_source: "stream_final", provider_response_id: "chatcmpl_s"
        )
      end
    end

    it "records token usage from chat.completions.stream_raw" do
      stub_sdk_sse(:post, "https://api.openai.com/v1/chat/completions", body: chat_sse_body)

      capture_sdk_events do |events|
        stream = client.chat.completions.stream_raw(
          model: "gpt-4o", messages: [{ role: "user", content: "hi" }]
        )
        stream.each { |_| }

        expect(events.first).to include(
          provider: "openai", stream: true, input_tokens: 10, output_tokens: 5
        )
      end
    end

    it "warns when a chat.completions stream ends without usage because include_usage was not requested" do
      sse = <<~SSE
        data: {"id":"chatcmpl_s","object":"chat.completion.chunk","model":"gpt-4o","choices":[{"index":0,"delta":{"content":"hi"}}]}

        data: [DONE]

      SSE
      stub_sdk_sse(:post, "https://api.openai.com/v1/chat/completions", body: sse)
      allow(LlmCostTracker::Logging).to receive(:warn)

      capture_sdk_events do |events|
        client.chat.completions.stream(model: "gpt-4o", messages: [{ role: "user", content: "hi" }]).each { |_| nil }

        expect(events.first).to include(usage_source: "unknown")
      end
      expect(LlmCostTracker::Logging).to have_received(:warn).with(/stream_options.*include_usage/)
    end

    it "records the per-call web search fee on streamed search-model completions, as create does" do
      chunk = { id: "chatcmpl_search", object: "chat.completion.chunk", model: "gpt-5-search-api-2025-10-14" }
      sse = [
        chunk.merge(choices: [{ index: 0, delta: { role: "assistant", content: "Rain today." } }]),
        chunk.merge(choices: [], usage: { prompt_tokens: 1_000, completion_tokens: 500, total_tokens: 1_500 })
      ].map { |data| "data: #{data.to_json}\n\n" }.join + "data: [DONE]\n\n"
      stub_sdk_sse(:post, "https://api.openai.com/v1/chat/completions", body: sse)
      messages = [{ role: "user", content: "Weather in Paris?" }]

      capture_sdk_events do |events|
        client.chat.completions.stream_raw(model: "gpt-5-search-api", messages: messages).each { |_| nil }
        client.chat.completions.stream(model: "gpt-5-search-api", messages: messages).each { |_| nil }

        expect(events.size).to eq(2)
        events.each do |event|
          fee = event[:line_items].find { |item| item[:kind] == "web_search_preview_request_reasoning" }
          expect(fee).to include(provider_item_id: "chatcmpl_search", cost: "0.01")
          expect(BigDecimal(event.dig(:cost, :total).to_s)).to eq(BigDecimal("0.01625"))
        end
      end
    end

    it "records usage from a chat.completions.stream_raw stream far longer than the capture limit" do
      chunk = { id: "chatcmpl_long", object: "chat.completion.chunk", model: "gpt-4o",
                choices: [{ index: 0, delta: { content: " token" } }] }
      body = +""
      20_000.times { body << "data: #{chunk.to_json}\n\n" }
      final = chunk.merge(choices: [], usage: { prompt_tokens: 10, completion_tokens: 20_000, total_tokens: 20_010 })
      body << "data: #{final.to_json}\n\ndata: [DONE]\n\n"
      stub_sdk_sse(:post, "https://api.openai.com/v1/chat/completions", body: body)

      capture_sdk_events do |events|
        stream = client.chat.completions.stream_raw(model: "gpt-4o", messages: [{ role: "user", content: "hi" }])
        stream.each { |_| nil }

        expect(events.first).to include(usage_source: "stream_final", input_tokens: 10, output_tokens: 20_000,
                                        provider_response_id: "chatcmpl_long")
      end
    end

    it "records usage from a chat.completions.stream with logprobs, whose helper events resend every logprob so far" do
      chunk = { id: "chatcmpl_lp", object: "chat.completion.chunk", model: "gpt-4.1-mini" }
      body = +""
      logprobs.each do |entry|
        choice = { index: 0, delta: { content: entry[:token] }, logprobs: { content: [entry] }, finish_reason: nil }
        body << "data: #{chunk.merge(choices: [choice]).to_json}\n\n"
      end
      body << "data: #{chunk.merge(choices: [{ index: 0, delta: {}, finish_reason: 'stop' }]).to_json}\n\n"
      usage = { prompt_tokens: 50, completion_tokens: 500, total_tokens: 550 }
      body << "data: #{chunk.merge(choices: [], usage: usage).to_json}\n\ndata: [DONE]\n\n"
      stub_sdk_sse(:post, "https://api.openai.com/v1/chat/completions", body: body)

      capture_sdk_events do |events|
        client.chat.completions.stream(
          model: "gpt-4.1-mini", messages: [{ role: "user", content: "hi" }], logprobs: true, top_logprobs: 20,
          stream_options: { include_usage: true }
        ).each { |_| nil }

        expect(events.first).to include(usage_source: "stream_final", input_tokens: 50, output_tokens: 500)
      end
    end

    it "prices the tier the stream reports when the requested priority tier was downgraded" do
      stub_sdk_sse(:post, "https://api.openai.com/v1/chat/completions", body: <<~SSE)
        data: {"id":"chatcmpl_d","object":"chat.completion.chunk","model":"gpt-5.5","service_tier":"default","choices":[],"usage":{"prompt_tokens":10000,"completion_tokens":2000,"total_tokens":12000}}

        data: [DONE]

      SSE

      capture_sdk_events do |events|
        client.chat.completions.stream_raw(
          model: "gpt-5.5", service_tier: :priority, messages: [{ role: "user", content: "hi" }]
        ).each { |_| nil }

        expect(events.first[:pricing_mode]).to be_nil
        expect(BigDecimal(events.first[:cost][:total])).to eq(BigDecimal("0.11"))
      end
    end

    it "falls back to the requested tier when the stream reports none" do
      stub_sdk_sse(:post, "https://api.openai.com/v1/chat/completions", body: chat_sse_body)

      capture_sdk_events do |events|
        client.chat.completions.stream_raw(
          model: "gpt-4o", service_tier: :priority, messages: [{ role: "user", content: "hi" }]
        ).each { |_| nil }

        expect(events.first[:pricing_mode]).to eq("priority")
      end
    end

    it "lets consumed chat.completions.stream_raw streams be garbage-collected" do
      stub_sdk_sse(:post, "https://api.openai.com/v1/chat/completions", body: chat_sse_body)

      consume = lambda do
        stream = client.chat.completions.stream_raw(model: "gpt-4o", messages: [{ role: "user", content: "hi" }])
        stream.each { |_| nil }
        WeakRef.new(stream)
      end
      refs = Array.new(20) { consume.call }
      3.times { GC.start(full_mark: true, immediate_sweep: true) }

      expect(refs.count(&:weakref_alive?)).to be < 5
    end
  end

  describe "responses streaming" do
    let(:responses_sse_body) do
      <<~SSE
        event: response.created
        data: {"type":"response.created","response":{"id":"resp_stream","model":"gpt-4o"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_stream","model":"gpt-4o","usage":{"input_tokens":20,"output_tokens":7,"total_tokens":27}}}

      SSE
    end

    it "records token usage from responses.stream" do
      stub_sdk_sse(:post, "https://api.openai.com/v1/responses", body: responses_sse_body)

      capture_sdk_events do |events|
        stream = client.responses.stream(model: "gpt-4o", input: "hi")
        stream.each { |_| }

        expect(events.first).to include(
          provider: "openai", model: "gpt-4o", stream: true,
          input_tokens: 20, output_tokens: 7,
          usage_source: "stream_final", provider_response_id: "resp_stream"
        )
      end
    end

    it "records token usage from responses.stream_raw" do
      stub_sdk_sse(:post, "https://api.openai.com/v1/responses", body: responses_sse_body)

      capture_sdk_events do |events|
        stream = client.responses.stream_raw(model: "gpt-4o", input: "hi")
        stream.each { |_| }

        expect(events.first).to include(
          provider: "openai", model: "gpt-4o", stream: true,
          input_tokens: 20, output_tokens: 7,
          provider_response_id: "resp_stream"
        )
      end
    end

    it "records usage from a responses stream whose completed event carries output_text logprobs" do
      text = { type: "output_text", text: logprobs.pluck(:token).join, annotations: [], logprobs: logprobs }
      response = { id: "resp_lp", model: "gpt-4.1-mini", status: "completed",
                   output: [{ type: "message", id: "msg_lp", role: "assistant", status: "completed", content: [text] }],
                   usage: { input_tokens: 50, output_tokens: 500, total_tokens: 550 } }
      completed = { type: "response.completed", response: response }
      stub_sdk_sse(:post, "https://api.openai.com/v1/responses",
                   body: "event: response.completed\ndata: #{completed.to_json}\n\n")

      capture_sdk_events do |events|
        client.responses.stream_raw(
          model: "gpt-4.1-mini", input: "hi", top_logprobs: 20, include: ["message.output_text.logprobs"]
        ).each { |_| nil }

        expect(events.first).to include(usage_source: "stream_final", input_tokens: 50, output_tokens: 500)
      end
    end

    it "records token usage from responses.retrieve_streaming, falling back to the URL response id when SSE chunks omit it" do
      idless_sse = <<~SSE
        event: response.completed
        data: {"type":"response.completed","response":{"model":"gpt-4o","usage":{"input_tokens":20,"output_tokens":7,"total_tokens":27}}}

      SSE
      stub_sdk_sse(:get, "https://api.openai.com/v1/responses/resp_retrieve?stream=true", body: idless_sse)

      capture_sdk_events do |events|
        stream = client.responses.retrieve_streaming("resp_retrieve")
        stream.each { |_| }

        expect(events.first).to include(
          provider: "openai", stream: true,
          input_tokens: 20, output_tokens: 7,
          provider_response_id: "resp_retrieve"
        )
      end
    end
  end

  describe "images streaming" do
    def image_sse_body(type)
      <<~SSE
        event: #{type}
        data: {"type":"#{type}","b64_json":"","background":"opaque","created_at":1700000000,"output_format":"png","quality":"high","size":"1024x1024","usage":{"input_tokens":10,"output_tokens":1500,"total_tokens":1510,"input_tokens_details":{"image_tokens":0,"text_tokens":10}}}

      SSE
    end

    it "records token usage from images.generate_stream_raw" do
      stub_sdk_sse(:post, "https://api.openai.com/v1/images/generations",
                   body: image_sse_body("image_generation.completed"))

      capture_sdk_events do |events|
        stream = client.images.generate_stream_raw(
          prompt: "a cat", model: "gpt-image-1", partial_images: 1
        )
        stream.each { |_| }

        expect(events.first).to include(
          provider: "openai", model: "gpt-image-1", stream: true,
          input_tokens: 10, image_output_tokens: 1500, output_tokens: 0, usage_source: "stream_final"
        )
      end
    end

    it "records token usage from images.edit_stream_raw" do
      stub_sdk_sse(:post, "https://api.openai.com/v1/images/edits",
                   body: image_sse_body("image_edit.completed"))

      capture_sdk_events do |events|
        stream = client.images.edit_stream_raw(
          image: image_io, prompt: "make it blue", model: "gpt-image-1", partial_images: 1
        )
        stream.each { |_| }

        expect(events.first).to include(
          provider: "openai", model: "gpt-image-1", stream: true,
          input_tokens: 10, image_output_tokens: 1500, output_tokens: 0, usage_source: "stream_final"
        )
      end
    end
  end

  describe "audio.transcriptions.create_streaming" do
    let(:transcription_sse_body) do
      <<~SSE
        event: transcript.text.done
        data: {"type":"transcript.text.done","text":"hello world","usage":{"type":"tokens","input_tokens":4,"output_tokens":3,"total_tokens":7,"input_token_details":{"audio_tokens":4,"text_tokens":0}}}

      SSE
    end

    it "records token usage from streaming transcription" do
      stub_sdk_sse(:post, "https://api.openai.com/v1/audio/transcriptions", body: transcription_sse_body)

      capture_sdk_events do |events|
        stream = client.audio.transcriptions.create_streaming(file: audio_io, model: "gpt-4o-transcribe")
        stream.each { |_| }

        expect(events.first).to include(
          provider: "openai", model: "gpt-4o-transcribe", stream: true,
          input_tokens: 0, audio_input_tokens: 4, output_tokens: 3, usage_source: "stream_final"
        )
      end
    end
  end

  describe "chat.completions search line items" do
    it "synthesizes a web_search line item from a url_citation annotation" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 200,
        body: {
          id: "chatcmpl_a", object: "chat.completion", model: "gpt-4o",
          choices: [{
            index: 0,
            message: {
              role: "assistant", content: "see source",
              annotations: [{ type: "url_citation",
                              url_citation: { url: "https://example.com", title: "x" } }]
            },
            finish_reason: "stop"
          }],
          usage: { prompt_tokens: 5, completion_tokens: 2, total_tokens: 7 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        client.chat.completions.create(model: "gpt-4o", messages: [{ role: "user", content: "x" }])
        kinds = events.first[:line_items].reject { |item| item[:unit] == "token" }.map { |item| item[:kind] }
        expect(kinds).to contain_exactly("web_search_request")
      end
    end

    it "synthesizes a search-preview line item for a *-search-preview model with no annotations" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
        status: 200,
        body: {
          id: "chatcmpl_b", object: "chat.completion", model: "gpt-4o-search-preview",
          choices: [{ index: 0, message: { role: "assistant", content: "hi" }, finish_reason: "stop" }],
          usage: { prompt_tokens: 5, completion_tokens: 2, total_tokens: 7 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        client.chat.completions.create(model: "gpt-4o-search-preview",
                                       messages: [{ role: "user", content: "x" }])
        kinds = events.first[:line_items].reject { |item| item[:unit] == "token" }.map { |item| item[:kind] }
        expect(kinds).to contain_exactly("web_search_preview_request_non_reasoning")
      end
    end
  end

  describe "responses.create extras" do
    it "captures the priority service tier as a pricing mode" do
      stub_sdk_json(:post, "https://api.openai.com/v1/responses",
                    provider: :openai, fixture: "responses_with_service_tier.json")

      capture_sdk_events do |events|
        client.responses.create(model: "gpt-4o", input: "hi")
        expect(events.first[:pricing_mode]).to eq("priority")
      end
    end

    it "marks an image_generation tool call partial because Responses usage leaves the image charge out" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/responses").to_return(
        status: 200,
        body: { id: "resp_img", object: "response", created_at: 1, model: "gpt-5.5-2026-04-23", status: "completed",
                output: [{ type: "image_generation_call", id: "ig_1", status: "completed", result: "iVBORw0KGgo=" }],
                usage: { input_tokens: 2_000, input_tokens_details: { cached_tokens: 0 },
                         output_tokens: 200, output_tokens_details: { reasoning_tokens: 0 },
                         total_tokens: 2_200 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        client.responses.create(model: "gpt-5.5", input: "Draw a cat", tools: [{ type: :image_generation }])

        image_line = events.first[:line_items].find { |item| item[:kind] == "image_generation_call" }
        expect(image_line).to include(provider_item_id: "ig_1", cost_status: "unknown")
        expect(events.first).to include(cost_status: "partial")
      end
    end

    it "records hosted-tool calls as service line items, deduplicating containers by id" do
      stub_sdk_json(:post, "https://api.openai.com/v1/responses",
                    provider: :openai, fixture: "responses_with_tool_output.json")

      capture_sdk_events do |events|
        client.responses.create(model: "gpt-4o", input: "hi")
        kinds = events.first[:line_items].reject { |item| item[:unit] == "token" }.map { |item| item[:kind] }
        expect(kinds).to contain_exactly("web_search_request", "file_search_call", "container_session")
      end
    end
  end

  describe "Azure OpenAI base_url" do
    let(:azure_client) do
      OpenAI::Client.new(api_key: "test-key", base_url: "https://my-resource.openai.azure.com/openai/v1/")
    end

    it "tags responses.create as azure_openai when the SDK client targets *.openai.azure.com" do
      stub_sdk_json(:post, "https://my-resource.openai.azure.com/openai/v1/responses",
                    provider: :openai, fixture: "responses_create.json")

      capture_sdk_events do |events|
        azure_client.responses.create(model: "gpt-4o", input: "hi")
        expect(events.first).to include(provider: "azure_openai")
      end
    end

    it "enforces budget against the azure_openai provider key so Azure-specific rates apply pre-call" do
      stub_sdk_json(:post, "https://my-resource.openai.azure.com/openai/v1/responses",
                    provider: :openai, fixture: "responses_create.json")
      allow(LlmCostTracker::Budget).to receive(:enforce!)

      azure_client.responses.create(model: "gpt-4o", input: "hi")

      expect(LlmCostTracker::Budget).to have_received(:enforce!).with(
        hash_including(provider: "azure_openai", model: "gpt-4o")
      )
    end

    it "enforces budget against azure_openai on streaming Azure calls too" do
      sse = <<~SSE
        data: {"id":"chatcmpl_s","object":"chat.completion.chunk","model":"gpt-4o","choices":[{"index":0,"delta":{"content":"hi"}}]}

        data: {"id":"chatcmpl_s","object":"chat.completion.chunk","model":"gpt-4o","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}

        data: [DONE]

      SSE
      stub_sdk_sse(:post, "https://my-resource.openai.azure.com/openai/v1/chat/completions", body: sse)
      allow(LlmCostTracker::Budget).to receive(:enforce!)

      stream = azure_client.chat.completions.stream(
        model: "gpt-4o", messages: [{ role: "user", content: "hi" }]
      )
      stream.each { |_| }

      expect(LlmCostTracker::Budget).to have_received(:enforce!).with(
        hash_including(provider: "azure_openai", model: "gpt-4o")
      )
    end

    it "prices a responses stream at standard when Azure downgrades a priority request" do
      stub_sdk_sse(:post, "https://my-resource.openai.azure.com/openai/v1/responses", body: <<~SSE)
        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_az","model":"gpt-4.1","service_tier":"default","usage":{"input_tokens":150000,"output_tokens":2000,"total_tokens":152000}}}

      SSE

      capture_sdk_events do |events|
        azure_client.responses.stream_raw(model: "gpt-4.1", input: "hi", service_tier: :priority).each { |_| nil }

        expect(events.first).to include(provider: "azure_openai", pricing_mode: nil)
        expect(BigDecimal(events.first[:cost][:total])).to eq(BigDecimal("0.316"))
      end
    end

    it "tags chat.completions.create as azure_openai under the same base_url" do
      stub_sdk_json(:post, "https://my-resource.openai.azure.com/openai/v1/chat/completions",
                    provider: :openai, fixture: "chat_completions_create.json")

      capture_sdk_events do |events|
        azure_client.chat.completions.create(model: "gpt-4o", messages: [{ role: "user", content: "hi" }])
        expect(events.first).to include(provider: "azure_openai")
      end
    end

    it "tags embeddings.create as azure_openai under the same base_url" do
      stub_sdk_json(:post, "https://my-resource.openai.azure.com/openai/v1/embeddings",
                    provider: :openai, fixture: "embeddings_create.json")

      capture_sdk_events do |events|
        azure_client.embeddings.create(model: "text-embedding-3-large", input: "hi")
        expect(events.first).to include(provider: "azure_openai")
      end
    end

    it "also recognises the services.ai.azure.com host as Azure" do
      stub_sdk_json(:post, "https://my-resource.services.ai.azure.com/openai/v1/responses",
                    provider: :openai, fixture: "responses_create.json")
      client = OpenAI::Client.new(api_key: "test-key",
                                  base_url: "https://my-resource.services.ai.azure.com/openai/v1/")

      capture_sdk_events do |events|
        client.responses.create(model: "gpt-4o", input: "hi")
        expect(events.first).to include(provider: "azure_openai")
      end
    end

    it "keeps the openai provider tag when the base_url is the public api.openai.com" do
      stub_sdk_json(:post, "https://api.openai.com/v1/responses",
                    provider: :openai, fixture: "responses_create.json")

      capture_sdk_events do |events|
        client.responses.create(model: "gpt-4o", input: "hi")
        expect(events.first).to include(provider: "openai")
      end
    end
  end

  describe "OpenAI-compatible base_url" do
    it "records a Groq call under groq and prices it from the groq/ entry" do
      WebMock.stub_request(:post, "https://api.groq.com/openai/v1/chat/completions").to_return(
        status: 200,
        body: { id: "chatcmpl-groq", object: "chat.completion", created: 1, model: "openai/gpt-oss-120b",
                choices: [{ index: 0, message: { role: "assistant", content: "hi" }, finish_reason: "stop" }],
                usage: { prompt_tokens: 10_000, completion_tokens: 1_000, total_tokens: 11_000 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
      groq = OpenAI::Client.new(api_key: "test-key", base_url: "https://api.groq.com/openai/v1")

      capture_sdk_events do |events|
        groq.chat.completions.create(model: "openai/gpt-oss-120b", messages: [{ role: "user", content: "hi" }])

        # Groq lists gpt-oss-120b at $0.15/M input and $0.60/M output.
        expect(events.first).to include(provider: "groq", cost_status: "complete")
        expect(BigDecimal(events.first.dig(:cost, :total))).to eq(BigDecimal("0.0021"))
      end
    end

    it "records OpenRouter's billed usage.cost from the final chunk of a stream" do
      chunk = { id: "gen-1", object: "chat.completion.chunk", created: 1, model: "meta-llama/llama-3.3-70b-instruct",
                choices: [{ index: 0, delta: { content: "hi" } }] }
      final = chunk.merge(choices: [], usage: { prompt_tokens: 3_000, completion_tokens: 500, total_tokens: 3_500,
                                                cost: 0.00364, is_byok: false })
      stub_sdk_sse(:post, "https://openrouter.ai/api/v1/chat/completions",
                   body: "data: #{chunk.to_json}\n\ndata: #{final.to_json}\n\ndata: [DONE]\n\n")
      openrouter = OpenAI::Client.new(api_key: "test-key", base_url: "https://openrouter.ai/api/v1")

      capture_sdk_events do |events|
        openrouter.chat.completions.stream_raw(
          model: "meta-llama/llama-3.3-70b-instruct", messages: [{ role: "user", content: "hi" }],
          stream_options: { include_usage: true }
        ).each { |_| nil }

        # Together serves llama-3.3-70b-instruct at $1.04/M input and output; the list price is $0.10/$0.32.
        expect(events.first).to include(provider: "openrouter", cost_status: "complete")
        expect(BigDecimal(events.first.dig(:cost, :total))).to eq(BigDecimal("0.00364"))
      end
    end
  end

  describe "data residency pricing" do
    let(:dr_client) { OpenAI::Client.new(api_key: "test-key", base_url: "https://us.api.openai.com/v1/") }

    def stub_responses_for(model)
      WebMock.stub_request(:post, "https://us.api.openai.com/v1/responses").to_return(
        status: 200,
        body: { id: "resp_dr", object: "response", model: model, status: "completed",
                created_at: 1, output: [],
                usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    end

    it "applies data_residency pricing mode for an uplifted model on us.api.openai.com" do
      stub_responses_for("gpt-5.4-mini")

      capture_sdk_events do |events|
        dr_client.responses.create(model: "gpt-5.4-mini", input: "hi")
        expect(events.first).to include(provider: "openai", pricing_mode: "data_residency")
      end
    end

    it "keeps data_residency on streams from the regional host" do
      stub_sdk_sse(:post, "https://us.api.openai.com/v1/responses", body: <<~SSE)
        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_dr","model":"gpt-5.4-mini","service_tier":"default","usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}

      SSE

      capture_sdk_events do |events|
        dr_client.responses.stream_raw(model: "gpt-5.4-mini", input: "hi").each { |_| nil }
        expect(events.first).to include(provider: "openai", pricing_mode: "data_residency")
      end
    end

    it "does not apply data_residency for non-uplifted models on the same host" do
      stub_responses_for("gpt-4o")

      capture_sdk_events do |events|
        dr_client.responses.create(model: "gpt-4o", input: "hi")
        expect(events.first[:pricing_mode]).to be_nil
      end
    end
  end

  describe "gpt-image model splits" do
    it "routes Responses.create output to image_output_tokens when usage omits the output detail split" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/responses").to_return(
        status: 200,
        body: {
          id: "resp_image", object: "response", model: "gpt-image-1", status: "completed",
          created_at: 1, output: [],
          usage: { input_tokens: 0, output_tokens: 200, total_tokens: 200 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        client.responses.create(model: "gpt-image-1", input: "draw")
        expect(events.first).to include(provider: "openai", model: "gpt-image-1",
                                        output_tokens: 0, image_output_tokens: 200)
      end
    end

    it "splits image input tokens from text for gpt-image-1" do
      WebMock.stub_request(:post, "https://api.openai.com/v1/images/generations").to_return(
        status: 200,
        body: {
          created: 1, data: [],
          usage: {
            input_tokens: 30, output_tokens: 0, total_tokens: 30,
            input_tokens_details: { image_tokens: 15, text_tokens: 15 }
          }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        client.images.generate(prompt: "a cat", model: "gpt-image-1")
        expect(events.first).to include(
          input_tokens: 15, image_input_tokens: 15,
          output_tokens: 0, image_output_tokens: 0
        )
      end
    end
  end
end
