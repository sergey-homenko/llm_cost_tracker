# frozen_string_literal: true

require "aws-eventstream"
require "tempfile"

module AccountingCases
  GEMINI_PAINT_ON_RUBY_LLM_1 = "Gemini image models paint through generateContent only on RubyLLM 2.x"
  CONTEXT_TRANSCRIBE_ON_RUBY_LLM_1 = "RubyLLM::Context#transcribe exists only on RubyLLM 2.x"
  STREAMED_TRANSCRIBE_ON_RUBY_LLM_1 = "RubyLLM 1.x does not stream transcriptions"
  RUBY_LLM_2_ONLY = "RubyLLM 1.x has no per-attempt usage events, workflows, batches, speech, OCR or rerank"
  CONVERSE_STREAM_ON_RUBY_LLM_1 = "RubyLLM 1.x Converse streams are frozen at their 0.14.2 accounting"
  CONVERSE_STREAM_URL = %r{\Ahttps://bedrock-runtime\.[a-z0-9-]+\.amazonaws\.com/model/[^/]+/converse-stream\z}
  PNG_PART = { inlineData: { mimeType: "image/png", data: "iVBORw0KGgo=" } }.freeze

  def ruby_llm_chat(model, provider, context: RubyLLM)
    context.chat(model: model, provider: provider, assume_model_exists: true)
  end

  def stub_ruby_llm_openai(host:, id:, model:, usage:, service_tier: nil)
    stub_json(:post, "https://#{host}/v1/chat/completions",
              chat_completion(id: id, model: model, usage: usage, service_tier: service_tier))
    responses = usage && {
      input_tokens: usage[:prompt_tokens], output_tokens: usage[:completion_tokens], total_tokens: usage[:total_tokens],
      input_tokens_details: { cached_tokens: usage.dig(:prompt_tokens_details, :cached_tokens).to_i },
      output_tokens_details: { reasoning_tokens: usage.dig(:completion_tokens_details, :reasoning_tokens).to_i }
    }
    stub_json(:post, "https://#{host}/v1/responses",
              responses_object(id: id, model: model, usage: responses, service_tier: service_tier))
  end

  def ruby_llm_transcribe(model, provider, context: RubyLLM, &)
    Tempfile.create(["clip", ".wav"]) do |file|
      file.binmode
      file.write("RIFF....WAVEfmt ")
      file.flush
      context.transcribe(file.path, model: model, provider: provider, assume_model_exists: true, &)
    end
  end

  def bedrock_context(region)
    RubyLLM.context do |config|
      config.bedrock_api_key = "AKIATEST"
      config.bedrock_secret_key = "test-secret"
      config.bedrock_region = region
    end
  end

  def converse_frame(type, data)
    headers = { ":message-type" => "event", ":event-type" => type, ":content-type" => "application/json" }
              .transform_values { |value| Aws::EventStream::HeaderValue.new(value: value, type: "string") }
    Aws::EventStream::Encoder.new.encode(Aws::EventStream::Message.new(headers: headers,
                                                                      payload: StringIO.new(JSON.generate(data))))
  end

  def stub_converse_stream(usage)
    body = [converse_frame("messageStart", { role: "assistant" }),
            converse_frame("contentBlockDelta", { contentBlockIndex: 0, delta: { text: "hi" } }),
            converse_frame("contentBlockStop", { contentBlockIndex: 0 }),
            converse_frame("messageStop", { stopReason: "end_turn" }),
            converse_frame("metadata", { usage: usage, metrics: { latencyMs: 640 } })].join
    WebMock.stub_request(:post, CONVERSE_STREAM_URL)
           .to_return(status: 200, body: body, headers: { "Content-Type" => "application/vnd.amazon.eventstream" })
  end

  def converse_usage(input, output, cache_read: 0, one_hour: 0, five_minute: 0)
    details = [({ ttl: "1h", inputTokens: one_hour } if one_hour.positive?),
               ({ ttl: "5m", inputTokens: five_minute } if five_minute.positive?)].compact
    { inputTokens: input, outputTokens: output, cacheReadInputTokens: cache_read,
      cacheWriteInputTokens: one_hour + five_minute, cacheDetails: details,
      totalTokens: input + output + cache_read + one_hour + five_minute }
  end

  def gemini_paint_response(model, usage, parts: [PNG_PART])
    { candidates: [{ content: { role: "model", parts: parts }, finishReason: "STOP" }], usageMetadata: usage,
      modelVersion: model }
  end

  define_case "ruby_llm openai chat: cached and reasoning tokens", instrument: :ruby_llm do
    stub_ruby_llm_openai(host: "api.openai.com", id: "chatcmpl_rl1", model: "gpt-4o",
                         usage: chat_usage(100, 30, cached: 25, reasoning: 8))
    ruby_llm_chat("gpt-4o", :openai).ask("hi")
  end

  define_case "ruby_llm openai chat: response without usage records nothing", instrument: :ruby_llm do
    stub_ruby_llm_openai(host: "api.openai.com", id: "chatcmpl_rl2", model: "gpt-4o", usage: nil)
    ruby_llm_chat("gpt-4o", :openai).ask("hi")
  end

  define_case "ruby_llm openai chat: gpt-5.4 on the eu host", instrument: :ruby_llm do
    stub_ruby_llm_openai(host: "eu.api.openai.com", id: "chatcmpl_rl3", model: "gpt-5.4",
                         usage: chat_usage(10_000, 1000))
    context = RubyLLM.context { |config| config.openai_api_base = "https://eu.api.openai.com/v1" }
    ruby_llm_chat("gpt-5.4", :openai, context: context).ask("hi")
  end

  define_case "ruby_llm openai chat: o3 served on flex", instrument: :ruby_llm do
    stub_ruby_llm_openai(host: "api.openai.com", id: "chatcmpl_rl4", model: "o3",
                         usage: chat_usage(20_000, 3000, reasoning: 2000), service_tier: "flex")
    ruby_llm_chat("o3", :openai).ask("hi")
  end

  define_case "ruby_llm openai chat: default service tier", instrument: :ruby_llm do
    stub_ruby_llm_openai(host: "api.openai.com", id: "chatcmpl_rl5", model: "gpt-4o", usage: chat_usage(1000, 100),
                         service_tier: "default")
    ruby_llm_chat("gpt-4o", :openai).ask("hi")
  end

  define_case "ruby_llm openai chat: gpt-5.4 long context with cached tokens", instrument: :ruby_llm do
    stub_ruby_llm_openai(host: "api.openai.com", id: "chatcmpl_rl6", model: "gpt-5.4",
                         usage: chat_usage(300_000, 2000, cached: 100_000))
    ruby_llm_chat("gpt-5.4", :openai).ask("hi")
  end

  define_case "ruby_llm openai chat stream: cached tokens", instrument: :ruby_llm do
    stub_sse(:post, "#{OPENAI_API}/chat/completions",
             chat_stream_body(id: "chatcmpl_rl7", model: "gpt-4o", usage: chat_usage(1000, 200, cached: 100)))
    stub_sse(:post, "#{OPENAI_API}/responses",
             responses_stream_body(id: "chatcmpl_rl7", model: "gpt-4o", usage: responses_usage(1000, 200, cached: 100)))
    ruby_llm_chat("gpt-4o", :openai).ask("hi") { nil }
  end

  define_case "ruby_llm anthropic chat: sonnet-4-5", instrument: :ruby_llm do
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_rl1", model: "claude-sonnet-4-5", usage: anthropic_usage(2000, 500)))
    ruby_llm_chat("claude-sonnet-4-5", :anthropic).ask("hi")
  end

  define_case "ruby_llm anthropic chat: 5m and 1h cache writes", instrument: :ruby_llm do
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_rl2", model: "claude-sonnet-4-5",
                                usage: anthropic_usage(10, 5, cache_5m: 100, cache_1h: 200)))
    ruby_llm_chat("claude-sonnet-4-5", :anthropic).ask("hi")
  end

  define_case "ruby_llm anthropic chat: us inference geo", instrument: :ruby_llm do
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_rl3", model: "claude-sonnet-4-6",
                                usage: { input_tokens: 10_000, output_tokens: 1000, inference_geo: "us" }))
    ruby_llm_chat("claude-sonnet-4-6", :anthropic).ask("hi")
  end

  define_case "ruby_llm anthropic chat: fast speed on opus-5-5", instrument: :ruby_llm do
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_rl4", model: "claude-opus-5-5",
                                usage: { input_tokens: 10_000, output_tokens: 1000, speed: "fast" }))
    ruby_llm_chat("claude-opus-5-5", :anthropic).ask("hi")
  end

  define_case "ruby_llm anthropic chat: served on priority", instrument: :ruby_llm do
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_rl5", model: "claude-sonnet-4-5",
                                usage: { input_tokens: 10, output_tokens: 5, service_tier: "priority" }))
    ruby_llm_chat("claude-sonnet-4-5", :anthropic).ask("hi")
  end

  define_case "ruby_llm anthropic chat: served on the batch tier", instrument: :ruby_llm do
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_rl6", model: "claude-sonnet-4-5",
                                usage: { input_tokens: 10, output_tokens: 5, service_tier: "batch" }))
    ruby_llm_chat("claude-sonnet-4-5", :anthropic).ask("hi")
  end

  define_case "ruby_llm anthropic chat: served on the standard tier", instrument: :ruby_llm do
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_rl6b", model: "claude-sonnet-4-5",
                                usage: { input_tokens: 10_000, output_tokens: 500, service_tier: "standard" }))
    ruby_llm_chat("claude-sonnet-4-5", :anthropic).ask("hi")
  end

  define_case "ruby_llm anthropic chat: pause_turn continuation with 5m cache writes", instrument: :ruby_llm do
    stub_json_sequence(
      :post, ANTHROPIC_MESSAGES,
      anthropic_message(id: "msg_seg1", model: "claude-sonnet-4-6", stop_reason: "pause_turn",
                        usage: { input_tokens: 20, output_tokens: 200, cache_creation_input_tokens: 8000,
                                 cache_creation: { ephemeral_5m_input_tokens: 8000, ephemeral_1h_input_tokens: 0 } }),
      anthropic_message(id: "msg_seg2", model: "claude-sonnet-4-6",
                        usage: { input_tokens: 30, output_tokens: 400, cache_read_input_tokens: 8000,
                                 cache_creation_input_tokens: 1500,
                                 cache_creation: { ephemeral_5m_input_tokens: 1500, ephemeral_1h_input_tokens: 0 } })
    )
    ruby_llm_chat("claude-sonnet-4-6", :anthropic).ask("research")
  end

  define_case "ruby_llm anthropic chat stream: 5m cache writes", instrument: :ruby_llm do
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_rl7", model: "claude-haiku-4-5",
                                   start_usage: anthropic_usage(11, 1, cache_5m: 500),
                                   delta_usage: { output_tokens: 9 }))
    ruby_llm_chat("claude-haiku-4-5", :anthropic).ask("hi") { nil }
  end

  define_case "ruby_llm anthropic chat stream: cache writes grow after message_start", instrument: :ruby_llm do
    start = { input_tokens: 79, cache_creation_input_tokens: 2600, cache_read_input_tokens: 0,
              cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: 2600 }, output_tokens: 3 }
    delta = { input_tokens: 79, cache_creation_input_tokens: 7924, cache_read_input_tokens: 2600, output_tokens: 510 }
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_rl8", model: "claude-sonnet-4-6", start_usage: start, delta_usage: delta))
    ruby_llm_chat("claude-sonnet-4-6", :anthropic).ask("hi") { nil }
  end

  define_case "ruby_llm gemini chat: thoughts tokens", instrument: :ruby_llm do
    stub_json(:post, gemini_url("gemini-2.5-flash"),
              gemini_response(model: "gemini-2.5-flash", id: "rlg1",
                              usage: gemini_usage(prompt: 1000, candidates: 300, thoughts: 200)))
    ruby_llm_chat("gemini-2.5-flash", :gemini).ask("hi")
  end

  define_case "ruby_llm gemini chat: image prompt", instrument: :ruby_llm do
    stub_json(:post, gemini_url("gemini-2.5-flash"),
              gemini_response(model: "gemini-2.5-flash", id: "rlg2",
                              usage: gemini_usage(prompt: 1300, candidates: 200,
                                                  prompt_details: modalities(TEXT: 10, IMAGE: 1290))))
    ruby_llm_chat("gemini-2.5-flash", :gemini).ask("hi")
  end

  define_case "ruby_llm gemini chat: cached tokens", instrument: :ruby_llm do
    stub_json(:post, gemini_url("gemini-2.5-flash"),
              gemini_response(model: "gemini-2.5-flash", id: "rlg3",
                              usage: gemini_usage(prompt: 10_000, candidates: 300, cached: 6000)))
    ruby_llm_chat("gemini-2.5-flash", :gemini).ask("hi")
  end

  define_case "ruby_llm gemini chat: priority service tier", instrument: :ruby_llm do
    stub_json(:post, gemini_url("gemini-2.5-flash"),
              gemini_response(model: "gemini-2.5-flash", id: "rlg4",
                              usage: gemini_usage(prompt: 10_000, candidates: 300, service_tier: "priority")))
    ruby_llm_chat("gemini-2.5-flash", :gemini).ask("hi")
  end

  define_case "ruby_llm gemini chat stream: thoughts on the standard tier", instrument: :ruby_llm do
    usage = gemini_usage(prompt: 5, candidates: 1, thoughts: 18, service_tier: "standard")
    stub_sse(:post, gemini_url("gemini-2.5-flash", stream: true),
             sse(gemini_response(model: "gemini-2.5-flash", id: "rlg5", usage: usage)))
    ruby_llm_chat("gemini-2.5-flash", :gemini).ask("hi") { nil }
  end

  define_case "ruby_llm gemini chat: 2.5-pro long context with thoughts", instrument: :ruby_llm do
    stub_json(:post, gemini_url("gemini-2.5-pro"),
              gemini_response(model: "gemini-2.5-pro", id: "rlg6",
                              usage: gemini_usage(prompt: 250_000, candidates: 3000, thoughts: 1000)))
    ruby_llm_chat("gemini-2.5-pro", :gemini).ask("hi")
  end

  define_case "ruby_llm openai embed: text-embedding-3-small", instrument: :ruby_llm do
    stub_json(:post, "#{OPENAI_API}/embeddings",
              { object: "list", model: "text-embedding-3-small", data: [{ embedding: [0.1] }],
                usage: { prompt_tokens: 7000, total_tokens: 7000 } })
    RubyLLM.embed("hi", model: "text-embedding-3-small", provider: :openai, assume_model_exists: true)
  end

  define_case "ruby_llm gemini embed: response without usage", instrument: :ruby_llm do
    url = %r{generativelanguage\.googleapis\.com/v1beta/models/gemini-embedding-001:(batchEmbedContents|embedContent)}
    stub_json(:post, url, { embeddings: [{ values: [0.1] }], embedding: { values: [0.1] } })
    RubyLLM.embed("hi", model: "gemini-embedding-001", provider: :gemini, assume_model_exists: true)
  end

  define_case "ruby_llm openai paint: gpt-image-1", instrument: :ruby_llm do
    stub_json(:post, "#{OPENAI_API}/images/generations",
              { created: 1, data: [{ url: "https://example.com/a.png" }],
                usage: { input_tokens: 50, output_tokens: 100, input_tokens_details: { image_tokens: 30 },
                         output_tokens_details: { image_tokens: 80 } } })
    RubyLLM.paint("a cat", model: "gpt-image-1", provider: :openai, assume_model_exists: true)
  end

  define_case "ruby_llm openai paint: response without usage", instrument: :ruby_llm do
    stub_json(:post, "#{OPENAI_API}/images/generations", { created: 1, data: [{ url: "https://example.com/a.png" }] })
    RubyLLM.paint("a cat", model: "gpt-image-1", provider: :openai, assume_model_exists: true)
  end

  define_case "ruby_llm gemini paint: 3.1-flash-image-preview",
              instrument: :ruby_llm, skip_on_ruby_llm_1: GEMINI_PAINT_ON_RUBY_LLM_1 do
    model = "gemini-3.1-flash-image-preview"
    usage = { promptTokenCount: 12, candidatesTokenCount: 1120, totalTokenCount: 1132,
              candidatesTokensDetails: modalities(IMAGE: 1120) }
    stub_json(:post, gemini_url(model), gemini_paint_response(model, usage))
    RubyLLM.paint("a watercolor fox", model: model, provider: :gemini, assume_model_exists: true)
  end

  define_case "ruby_llm gemini paint: 2.5-flash-image",
              instrument: :ruby_llm, skip_on_ruby_llm_1: GEMINI_PAINT_ON_RUBY_LLM_1 do
    model = "gemini-2.5-flash-image"
    usage = { promptTokenCount: 12, candidatesTokenCount: 1290, totalTokenCount: 1302,
              candidatesTokensDetails: modalities(IMAGE: 1290) }
    stub_json(:post, gemini_url(model), gemini_paint_response(model, usage))
    RubyLLM.paint("a watercolor fox", model: model, provider: :gemini, assume_model_exists: true)
  end

  define_case "ruby_llm openai transcribe: gpt-4o-transcribe token usage", instrument: :ruby_llm do
    stub_json(:post, "#{OPENAI_API}/audio/transcriptions",
              { text: "hi", usage: { type: "tokens", input_tokens: 1200, output_tokens: 300, total_tokens: 1500,
                                     input_token_details: { audio_tokens: 1150, text_tokens: 50 } } })
    ruby_llm_transcribe("gpt-4o-transcribe", :openai)
  end

  define_case "ruby_llm openai transcribe: gpt-transcribe duration usage", instrument: :ruby_llm do
    stub_json(:post, "#{OPENAI_API}/audio/transcriptions", { text: "hi", usage: { type: "duration", seconds: 600 } })
    ruby_llm_transcribe("gpt-transcribe", :openai)
  end

  define_case "ruby_llm openai transcribe: whisper-1 duration usage", instrument: :ruby_llm do
    stub_json(:post, "#{OPENAI_API}/audio/transcriptions",
              { text: "hi", duration: 125.5, usage: { type: "duration", seconds: 125.5 } })
    ruby_llm_transcribe("whisper-1", :openai)
  end

  define_case "ruby_llm gemini transcribe: 2.5-flash", instrument: :ruby_llm do
    stub_json(:post, gemini_url("gemini-2.5-flash"),
              { candidates: [{ content: { role: "model", parts: [{ text: "hi" }] }, finishReason: "STOP" }],
                usageMetadata: { promptTokenCount: 40, candidatesTokenCount: 5, thoughtsTokenCount: 2 } })
    ruby_llm_transcribe("gemini-2.5-flash", :gemini)
  end

  define_case "ruby_llm openai moderate: omni-moderation-latest", instrument: :ruby_llm do
    stub_json(:post, "#{OPENAI_API}/moderations",
              { id: "modr_x", model: "omni-moderation-latest",
                results: [{ flagged: false, categories: {}, category_scores: {} }] })
    RubyLLM.moderate("hi", model: "omni-moderation-latest", provider: :openai, assume_model_exists: true)
  end

  define_case "ruby_llm openrouter chat: billed cost", instrument: :ruby_llm do
    stub_json(:post, "#{OPENROUTER_API}/chat/completions",
              chat_completion(id: "gen-rl1", model: "openai/gpt-4o", usage: openrouter_usage(3000, 500, cost: 0.0123)))
    stub_json(:post, "#{OPENROUTER_API}/responses",
              responses_object(id: "gen-rl1", model: "openai/gpt-4o",
                               usage: responses_usage(3000, 500).merge(cost: 0.0123)))
    ruby_llm_chat("openai/gpt-4o", :openrouter).ask("hi")
  end

  define_case "ruby_llm deepseek chat: cache hit and miss fields", instrument: :ruby_llm do
    usage = chat_usage(1000, 200, cached: 600).merge(prompt_cache_hit_tokens: 600, prompt_cache_miss_tokens: 400)
    stub_json(:post, %r{api\.deepseek\.com/(v1/)?chat/completions},
              chat_completion(id: "rlds1", model: "deepseek-chat", usage: usage))
    ruby_llm_chat("deepseek-chat", :deepseek).ask("hi")
  end

  define_case "ruby_llm anthropic chat stream: 1h cache writes", instrument: :ruby_llm do
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_rl1h", model: "claude-sonnet-4-5",
                                   start_usage: anthropic_usage(100, 1, cache_1h: 5000),
                                   delta_usage: { output_tokens: 200 }))
    ruby_llm_chat("claude-sonnet-4-5", :anthropic).ask("hi") { nil }
  end

  define_case "ruby_llm anthropic chat: batch tier with us inference geo", instrument: :ruby_llm do
    usage = { input_tokens: 10_000, output_tokens: 1000, service_tier: "batch", inference_geo: "us" }
    stub_json(:post, ANTHROPIC_MESSAGES, anthropic_message(id: "msg_rlgb", model: "claude-sonnet-4-6", usage: usage))
    ruby_llm_chat("claude-sonnet-4-6", :anthropic).ask("hi")
  end

  define_case "ruby_llm anthropic chat: cache write total above its breakdown", instrument: :ruby_llm do
    usage = anthropic_usage(200, 500, cache_5m: 1000, cache_1h: 2000).merge(cache_creation_input_tokens: 4500)
    stub_json(:post, ANTHROPIC_MESSAGES, anthropic_message(id: "msg_rlcb", model: "claude-sonnet-4-6", usage: usage))
    ruby_llm_chat("claude-sonnet-4-6", :anthropic).ask("hi")
  end

  define_case "ruby_llm anthropic chat: pause_turn continuation with 1h cache writes first", instrument: :ruby_llm do
    stub_json_sequence(
      :post, ANTHROPIC_MESSAGES,
      anthropic_message(id: "msg_p1", model: "claude-sonnet-4-6", stop_reason: "pause_turn",
                        usage: { input_tokens: 20, output_tokens: 200, cache_creation_input_tokens: 8000,
                                 cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: 8000 } }),
      anthropic_message(id: "msg_p2", model: "claude-sonnet-4-6",
                        usage: { input_tokens: 30, output_tokens: 400, cache_read_input_tokens: 8000,
                                 cache_creation_input_tokens: 1500,
                                 cache_creation: { ephemeral_5m_input_tokens: 1500, ephemeral_1h_input_tokens: 0 } })
    )
    ruby_llm_chat("claude-sonnet-4-6", :anthropic).ask("research")
  end

  define_case "ruby_llm anthropic chat: pause_turn segment with an opus-5 advisor before the last",
              instrument: :ruby_llm, skip_on_ruby_llm_1: RUBY_LLM_2_ONLY do
    stub_json_sequence(
      :post, ANTHROPIC_MESSAGES,
      anthropic_message(id: "msg_pa1", model: "claude-sonnet-5", usage: advisor_usage, stop_reason: "pause_turn"),
      anthropic_message(id: "msg_pa2", model: "claude-sonnet-5", usage: anthropic_usage(2000, 500))
    )
    ruby_llm_chat("claude-sonnet-5", :anthropic).ask("research")
  end

  define_case "ruby_llm anthropic chat: pause_turn segment answered by a server-side fallback before the last",
              instrument: :ruby_llm, skip_on_ruby_llm_1: RUBY_LLM_2_ONLY do
    stub_json_sequence(
      :post, ANTHROPIC_MESSAGES,
      anthropic_message(id: "msg_pf1", model: "claude-opus-4-8", usage: FALLBACK_AFTER_OUTPUT_USAGE,
                        stop_reason: "pause_turn"),
      anthropic_message(id: "msg_pf2", model: "claude-fable-5-1", usage: anthropic_usage(1000, 100))
    )
    ruby_llm_chat("claude-fable-5-1", :anthropic).ask("research")
  end

  define_case "ruby_llm anthropic chat: pause_turn segments on standard speed and us geo that only the body reports",
              instrument: :ruby_llm, skip_on_ruby_llm_1: RUBY_LLM_2_ONLY do
    usage = anthropic_usage(10_000, 1000, extra: { speed: "standard", inference_geo: "us" })
    stub_json_sequence(
      :post, ANTHROPIC_MESSAGES,
      anthropic_message(id: "msg_ps1", model: "claude-opus-5-5", usage: usage, stop_reason: "pause_turn"),
      anthropic_message(id: "msg_ps2", model: "claude-opus-5-5", usage: usage)
    )
    ruby_llm_chat("claude-opus-5-5", :anthropic).with_provider_options(speed: "fast").ask("research")
  end

  define_case "ruby_llm anthropic chat: us geo and 1h cache writes when an after_message callback raises",
              instrument: :ruby_llm do
    usage = anthropic_usage(10_000, 1000, cache_1h: 2000, extra: { inference_geo: "us" })
    stub_json(:post, ANTHROPIC_MESSAGES, anthropic_message(id: "msg_rlam", model: "claude-sonnet-4-6", usage: usage))
    chat = ruby_llm_chat("claude-sonnet-4-6", :anthropic).after_message { raise ArgumentError, "save failed" }
    expect { chat.ask("hi") }.to raise_error(ArgumentError, "save failed")
  end

  define_case "ruby_llm gemini chat: grounding and priority tier when an after_message callback raises",
              instrument: :ruby_llm do
    stub_json(:post, gemini_url("gemini-3-flash-preview"),
              gemini_response(model: "gemini-3-flash-preview", id: "rlgam", grounding: %w[a b c],
                              usage: gemini_usage(prompt: 1000, candidates: 300, service_tier: "priority")))
    chat = ruby_llm_chat("gemini-3-flash-preview", :gemini).after_message { raise ArgumentError, "save failed" }
    expect { chat.ask("hi") }.to raise_error(ArgumentError, "save failed")
  end

  define_case "ruby_llm openai chat: gpt-4o on the us host", instrument: :ruby_llm do
    stub_ruby_llm_openai(host: "us.api.openai.com", id: "chatcmpl_rlus", model: "gpt-4o",
                         usage: chat_usage(10_000, 1000))
    context = RubyLLM.context { |config| config.openai_api_base = "https://us.api.openai.com/v1" }
    ruby_llm_chat("gpt-4o", :openai, context: context).ask("hi")
  end

  define_case "ruby_llm openai chat: gpt-5.5 priority on the eu host", instrument: :ruby_llm do
    stub_ruby_llm_openai(host: "eu.api.openai.com", id: "chatcmpl_rlep", model: "gpt-5.5",
                         usage: chat_usage(10_000, 1000), service_tier: "priority")
    context = RubyLLM.context { |config| config.openai_api_base = "https://eu.api.openai.com/v1" }
    ruby_llm_chat("gpt-5.5", :openai, context: context).ask("hi")
  end

  define_case "ruby_llm openai chat: api base pointed at openrouter with billed cost", instrument: :ruby_llm do
    stub_json(:post, "#{OPENROUTER_API}/chat/completions",
              chat_completion(id: "gen-rlob", model: "openai/gpt-4o", usage: openrouter_usage(3000, 500, cost: 0.0123)))
    stub_json(:post, "#{OPENROUTER_API}/responses",
              responses_object(id: "gen-rlob", model: "openai/gpt-4o",
                               usage: responses_usage(3000, 500).merge(cost: 0.0123)))
    context = RubyLLM.context { |config| config.openai_api_base = OPENROUTER_API }
    ruby_llm_chat("openai/gpt-4o", :openai, context: context).ask("hi")
  end

  define_case "ruby_llm openrouter chat stream: billed cost", instrument: :ruby_llm do
    stub_sse(:post, "#{OPENROUTER_API}/chat/completions",
             chat_stream_body(id: "gen-rls", model: "openai/gpt-4o", usage: openrouter_usage(3000, 500, cost: 0.0123)))
    stub_sse(:post, "#{OPENROUTER_API}/responses",
             responses_stream_body(id: "gen-rls", model: "openai/gpt-4o",
                                   usage: responses_usage(3000, 500).merge(cost: 0.0123)))
    ruby_llm_chat("openai/gpt-4o", :openrouter).ask("hi") { nil }
  end

  define_case "ruby_llm gemini paint: 3-pro-image text and image output with thoughts",
              instrument: :ruby_llm, skip_on_ruby_llm_1: GEMINI_PAINT_ON_RUBY_LLM_1 do
    model = "gemini-3-pro-image"
    usage = { promptTokenCount: 20, candidatesTokenCount: 1170, thoughtsTokenCount: 300, totalTokenCount: 1490,
              candidatesTokensDetails: modalities(IMAGE: 1120, TEXT: 50) }
    stub_json(:post, gemini_url(model), gemini_paint_response(model, usage, parts: [{ text: "Here you go" }, PNG_PART]))
    RubyLLM.paint("a fox", model: model, provider: :gemini, assume_model_exists: true)
  end

  define_case "ruby_llm gemini paint: 2.5-flash-image with image prompt tokens",
              instrument: :ruby_llm, skip_on_ruby_llm_1: GEMINI_PAINT_ON_RUBY_LLM_1 do
    model = "gemini-2.5-flash-image"
    usage = { promptTokenCount: 1300, candidatesTokenCount: 1290, totalTokenCount: 2590,
              promptTokensDetails: modalities(TEXT: 10, IMAGE: 1290), candidatesTokensDetails: modalities(IMAGE: 1290) }
    stub_json(:post, gemini_url(model), gemini_paint_response(model, usage))
    RubyLLM.paint("edit this", model: model, provider: :gemini, assume_model_exists: true)
  end

  define_case "ruby_llm openai transcribe: response without usage", instrument: :ruby_llm do
    stub_json(:post, "#{OPENAI_API}/audio/transcriptions", { text: "hi" })
    ruby_llm_transcribe("whisper-1", :openai)
  end

  define_case "ruby_llm openai transcribe: duration field without usage", instrument: :ruby_llm do
    stub_json(:post, "#{OPENAI_API}/audio/transcriptions",
              { text: "hi", duration: 125.5, language: "en", segments: [] })
    ruby_llm_transcribe("whisper-1", :openai)
  end

  define_case "ruby_llm gemini transcribe: 2.5-flash text and audio prompt details", instrument: :ruby_llm do
    stub_json(:post, gemini_url("gemini-2.5-flash"),
              { candidates: [{ content: { role: "model", parts: [{ text: "hi" }] }, finishReason: "STOP" }],
                usageMetadata: { promptTokenCount: 812, candidatesTokenCount: 50, totalTokenCount: 862,
                                 promptTokensDetails: modalities(TEXT: 12, AUDIO: 800) },
                modelVersion: "gemini-2.5-flash" })
    ruby_llm_transcribe("gemini-2.5-flash", :gemini)
  end

  define_case "ruby_llm gemini chat: cached audio", instrument: :ruby_llm do
    stub_json(:post, gemini_url("gemini-2.5-flash"),
              gemini_response(model: "gemini-2.5-flash", id: "rlgca", usage: gemini_cached_audio_usage(100)))
    ruby_llm_chat("gemini-2.5-flash", :gemini).ask("hi")
  end

  define_case "ruby_llm xai chat: grok-4.7 reasoning tokens with cached tokens", instrument: :ruby_llm do
    stub_json(:post, "#{XAI_API}/chat/completions",
              chat_completion(id: "xai_r8", model: "grok-4.7",
                              usage: xai_chat_usage(12_000, 500, reasoning: 2500, cached: 8000)))
    stub_json(:post, "#{XAI_API}/responses",
              responses_object(id: "xai_r8", model: "grok-4.7",
                               usage: xai_responses_usage(12_000, 500, reasoning: 2500, cached: 8000)))
    ruby_llm_chat("grok-4.7", :xai).ask("hi")
  end

  define_case "ruby_llm xai chat stream: grok-4.7 reasoning tokens", instrument: :ruby_llm do
    stub_sse(:post, "#{XAI_API}/chat/completions",
             chat_stream_body(id: "xai_r9", model: "grok-4.7",
                              usage: xai_chat_usage(12_000, 500, reasoning: 2500, cached: 8000)))
    stub_sse(:post, "#{XAI_API}/responses",
             responses_stream_body(id: "xai_r9", model: "grok-4.7",
                                   usage: xai_responses_usage(12_000, 500, reasoning: 2500, cached: 8000)))
    ruby_llm_chat("grok-4.7", :xai).ask("hi") { nil }
  end

  define_case "ruby_llm xai chat: grok-4.7 priority on the us host", instrument: :ruby_llm do
    stub_json(:post, "#{XAI_US_API}/chat/completions",
              chat_completion(id: "xai_r10", model: "grok-4.7", usage: xai_chat_usage(10_000, 10_000, reasoning: 0),
                              service_tier: "priority"))
    stub_json(:post, "#{XAI_US_API}/responses",
              responses_object(id: "xai_r10", model: "grok-4.7",
                               usage: xai_responses_usage(10_000, 10_000, reasoning: 0), service_tier: "priority"))
    context = RubyLLM.context { |config| config.xai_api_base = XAI_US_API }
    ruby_llm_chat("grok-4.7", :xai, context: context).ask("hi")
  end

  define_case "ruby_llm openai transcribe: gpt-transcribe on the eu host",
              instrument: :ruby_llm, skip_on_ruby_llm_1: CONTEXT_TRANSCRIBE_ON_RUBY_LLM_1 do
    stub_json(:post, "https://eu.api.openai.com/v1/audio/transcriptions",
              { text: "hi", usage: { type: "duration", seconds: 125 } })
    context = RubyLLM.context { |config| config.openai_api_base = "https://eu.api.openai.com/v1" }
    ruby_llm_transcribe("gpt-transcribe", :openai, context: context)
  end

  define_case "ruby_llm openai transcribe: whisper-1 json usage without duration", instrument: :ruby_llm do
    stub_json(:post, "#{OPENAI_API}/audio/transcriptions", { text: "hi", usage: { type: "duration", seconds: 126 } })
    ruby_llm_transcribe("whisper-1", :openai)
  end

  define_case "ruby_llm openai transcribe: whisper-1 verbose_json with duration usage", instrument: :ruby_llm do
    stub_json(:post, "#{OPENAI_API}/audio/transcriptions",
              { task: "transcribe", language: "english", duration: 95.2, text: "hi", segments: [],
                usage: { type: "duration", seconds: 96 } })
    ruby_llm_transcribe("whisper-1", :openai)
  end

  define_case "ruby_llm openai transcribe: whisper-1 verbose_json with 8.47s duration and 9s usage",
              instrument: :ruby_llm do
    stub_json(:post, "#{OPENAI_API}/audio/transcriptions",
              { task: "transcribe", language: "english", duration: 8.470000267028809, text: "hi", segments: [],
                usage: { type: "duration", seconds: 9 } })
    ruby_llm_transcribe("whisper-1", :openai)
  end

  define_case "ruby_llm openai transcribe: whisper-1 8.47s duration without usage", instrument: :ruby_llm do
    stub_json(:post, "#{OPENAI_API}/audio/transcriptions",
              { text: "hi", duration: 8.470000267028809, language: "en", segments: [] })
    ruby_llm_transcribe("whisper-1", :openai)
  end

  define_case "ruby_llm openai transcribe stream: gpt-4o-transcribe text and audio split",
              instrument: :ruby_llm, skip_on_ruby_llm_1: STREAMED_TRANSCRIBE_ON_RUBY_LLM_1 do
    usage = { input_tokens: 2400, input_token_details: { text_tokens: 120, audio_tokens: 2280 }, output_tokens: 450,
              total_tokens: 2850 }
    stub_sse(:post, "#{OPENAI_API}/audio/transcriptions",
             sse({ type: "transcript.text.delta", delta: "hi" },
                 { type: "transcript.text.done", text: "hi", usage: usage }))
    ruby_llm_transcribe("gpt-4o-transcribe", :openai) { nil }
  end

  define_case "ruby_llm openai chat: refused and maybe-billed attempts before a success",
              instrument: :ruby_llm, skip_on_ruby_llm_1: RUBY_LLM_2_ONLY do
    WebMock.stub_request(:post, "#{OPENAI_API}/responses").to_return(
      { status: 429, body: JSON.generate(error: { message: "Rate limit reached" }), headers: JSON_HEADERS },
      { status: 500, body: JSON.generate(error: { message: "Internal error" }), headers: JSON_HEADERS },
      { status: 200, headers: JSON_HEADERS,
        body: JSON.generate(responses_object(id: "resp_rlretry", model: "gpt-4o", usage: responses_usage(1000, 200))) }
    )
    context = RubyLLM.context { |config| config.retry_interval = config.retry_interval_randomness = 0 }
    ruby_llm_chat("gpt-4o", :openai, context: context).ask("hi")
  end

  define_case "ruby_llm anthropic chat: workflow name and step tags",
              instrument: :ruby_llm, skip_on_ruby_llm_1: RUBY_LLM_2_ONLY do
    stub_json(:post, ANTHROPIC_MESSAGES,
              anthropic_message(id: "msg_rlwf", model: "claude-sonnet-4-5", usage: anthropic_usage(2000, 500)))
    RubyLLM.workflow("Write article", id: "article-42") do |workflow|
      workflow.step("Draft") { ruby_llm_chat("claude-sonnet-4-5", :anthropic).ask("hi") }
    end
  end

  define_case "ruby_llm anthropic batch: each result once at batch rates across polls, Batch.find and the Anthropic SDK",
              instrument: :ruby_llm, configure: ->(config) { config.instrument(:anthropic) },
              skip_on_ruby_llm_1: RUBY_LLM_2_ONLY do
    batch = { id: "msgbatch_rl", type: "message_batch", processing_status: "ended",
              request_counts: { processing: 0, succeeded: 2, errored: 1, canceled: 0, expired: 0 } }
    stub_json(:post, "#{ANTHROPIC_MESSAGES}/batches", batch)
    stub_json(:get, "#{ANTHROPIC_MESSAGES}/batches/msgbatch_rl", batch)
    geo = { input_tokens: 1000, output_tokens: 500, cache_read_input_tokens: 20_000, service_tier: "batch",
            inference_geo: "us" }
    error = { type: "error", error: { type: "invalid_request_error", message: "bad" } }
    stub_anthropic_batch("msgbatch_rl", [
      anthropic_batch_result("1", anthropic_message(id: "msg_rlb2", model: "claude-sonnet-4-6", usage: geo)),
      { custom_id: "2", result: { type: "errored", error: error } },
      anthropic_batch_result("0", anthropic_message(id: "msg_rlb1", model: "claude-sonnet-4-5",
                                                    usage: anthropic_usage(10_000, 1000)))
    ])
    chats = %w[claude-sonnet-4-5 claude-sonnet-4-6 claude-sonnet-4-5].map do |model|
      ruby_llm_chat(model, :anthropic).ask_later("hi")
    end
    batch = RubyLLM.batch(chats)
    2.times { batch.messages }
    batch.cost
    RubyLLM::Batch.find("msgbatch_rl", provider: :anthropic).results
    anthropic_client.messages.batches.results_streaming("msgbatch_rl").each { nil }
  end

  define_case "ruby_llm openai batch: gpt-5.4 responses found through an eu host context, then by the OpenAI SDK",
              instrument: :ruby_llm, configure: ->(config) { config.instrument(:openai) },
              skip_on_ruby_llm_1: RUBY_LLM_2_ONLY do
    body = responses_object(id: "resp_rlb_eu", model: "gpt-5.4", usage: responses_usage(200_000, 20_000, cached: 50_000))
    stub_openai_batch(host: "eu.api.openai.com", batch_id: "batch_rl_eu", status: "completed", endpoint: "/v1/responses",
                      lines: [openai_batch_line("batch_req_rl_eu", "0", body)])
    context = RubyLLM.context { |config| config.openai_api_base = "https://eu.api.openai.com/v1" }
    RubyLLM::Batch.find("batch_rl_eu", provider: :openai, context: context).messages
    openai_client("https://eu.api.openai.com/v1").batches.retrieve("batch_rl_eu")
  end

  define_case "ruby_llm openai batch: embeddings keyed by batch id and position",
              instrument: :ruby_llm, skip_on_ruby_llm_1: RUBY_LLM_2_ONLY do
    embedding = lambda do |tokens|
      { object: "list", model: "text-embedding-3-small", data: [{ object: "embedding", index: 0, embedding: [0.1] }],
        usage: { prompt_tokens: tokens, total_tokens: tokens } }
    end
    stub_json(:post, "#{OPENAI_API}/files", { id: "file_in_rl_emb", object: "file", purpose: "batch", bytes: 1,
                                              filename: "ruby_llm_batch.jsonl", created_at: 1_758_000_000 })
    stub_json(:post, "#{OPENAI_API}/batches", { id: "batch_rl_emb", object: "batch", endpoint: "/v1/embeddings",
                                                status: "validating", input_file_id: "file_in_rl_emb",
                                                completion_window: "24h", created_at: 1_758_000_000 })
    stub_openai_batch(host: "api.openai.com", batch_id: "batch_rl_emb", status: "completed", endpoint: "/v1/embeddings",
                      lines: [openai_batch_line("batch_req_rle2", "1", embedding.call(10_000)),
                              openai_batch_line("batch_req_rle1", "0", embedding.call(40_000))])
    requests = %w[first second].map { |text| RubyLLM.embed_later(text, model: "text-embedding-3-small", provider: :openai) }
    RubyLLM.batch(requests).refresh.results
  end

  define_case "ruby_llm gemini batch: inline responses collected in a workflow step",
              instrument: :ruby_llm, skip_on_ruby_llm_1: RUBY_LLM_2_ONLY do
    response = gemini_response(model: "gemini-2.5-flash", id: "gem_rlb1",
                               usage: gemini_usage(prompt: 20_000, candidates: 2000))
    stub_json(:get, "https://generativelanguage.googleapis.com/v1beta/batches/rl_gem",
              { name: "batches/rl_gem", state: "BATCH_STATE_SUCCEEDED",
                batchStats: { requestCount: "1", successfulRequestCount: "1" },
                output: { inlinedResponses: { inlinedResponses: [{ response: response, metadata: { custom_id: "0" } }] } } })
    RubyLLM.workflow("Nightly summaries") do |workflow|
      workflow.step("Collect results") { RubyLLM::Batch.find("batches/rl_gem", provider: :gemini).messages }
    end
  end

  define_case "ruby_llm anthropic batch: collected inside a streamed chat, apart from the chat's own attempt",
              instrument: :ruby_llm, skip_on_ruby_llm_1: RUBY_LLM_2_ONLY do
    stub_json(:post, "#{ANTHROPIC_MESSAGES}/batches",
              { id: "msgbatch_rlin", type: "message_batch", processing_status: "ended",
                request_counts: { processing: 0, succeeded: 1, errored: 0, canceled: 0, expired: 0 } })
    stub_anthropic_batch("msgbatch_rlin", [anthropic_batch_result(
      "0", anthropic_message(id: "msg_rlin1", model: "claude-sonnet-4-5", usage: anthropic_usage(10_000, 1000))
    )])
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_rlin_chat", model: "claude-sonnet-4-5",
                                   start_usage: { input_tokens: 100, output_tokens: 1 }, delta_usage: { output_tokens: 20 }))
    batch = RubyLLM.batch([ruby_llm_chat("claude-sonnet-4-5", :anthropic).ask_later("hi")])
    collected = false
    ruby_llm_chat("claude-sonnet-4-5", :anthropic).ask("hi") do |_chunk|
      batch.messages unless collected
      collected = true
    end
  end

  define_case "ruby_llm openai speak: tts-1 by input characters",
              instrument: :ruby_llm, skip_on_ruby_llm_1: RUBY_LLM_2_ONLY do
    WebMock.stub_request(:post, "#{OPENAI_API}/audio/speech")
           .to_return(status: 200, body: "ID3".b, headers: { "Content-Type" => "audio/mpeg" })
    RubyLLM.speak("Hello, welcome to RubyLLM!", model: "tts-1", provider: :openai, assume_model_exists: true)
  end

  define_case "ruby_llm openai speak: gpt-4o-mini-tts without usage",
              instrument: :ruby_llm, skip_on_ruby_llm_1: RUBY_LLM_2_ONLY do
    WebMock.stub_request(:post, "#{OPENAI_API}/audio/speech")
           .to_return(status: 200, body: "ID3".b, headers: { "Content-Type" => "audio/mpeg" })
    RubyLLM.speak("Hello, welcome to RubyLLM!", model: "gpt-4o-mini-tts", provider: :openai, assume_model_exists: true)
  end

  define_case "ruby_llm mistral ocr: mistral-ocr-latest without a price",
              instrument: :ruby_llm, skip_on_ruby_llm_1: RUBY_LLM_2_ONLY do
    stub_json(:post, "https://api.mistral.ai/v1/ocr",
              { pages: [{ index: 0, markdown: "# Invoice", images: [], dimensions: { dpi: 200, height: 2200, width: 1700 } }],
                model: "mistral-ocr-2505", usage_info: { pages_processed: 1, doc_size_bytes: 48_213 } })
    context = RubyLLM.context { |config| config.mistral_api_key = "test-mistral" }
    RubyLLM.ocr("https://example.com/invoice.pdf", model: "mistral-ocr-latest", provider: :mistral,
                                                   assume_model_exists: true, context: context)
  end

  define_case "ruby_llm cohere rerank: rerank-v3.5 without a price",
              instrument: :ruby_llm, skip_on_ruby_llm_1: RUBY_LLM_2_ONLY do
    stub_json(:post, "https://api.cohere.com/v2/rerank",
              { id: "rr_rl", results: [{ index: 1, relevance_score: 0.91 }, { index: 0, relevance_score: 0.12 }],
                meta: { api_version: { version: "2" }, billed_units: { search_units: 1 } } })
    context = RubyLLM.context { |config| config.cohere_api_key = "test-cohere" }
    RubyLLM.rerank("ruby", %w[python ruby], model: "rerank-v3.5", provider: :cohere, assume_model_exists: true,
                                            context: context)
  end

  define_case "ruby_llm openrouter rerank: billed cost",
              instrument: :ruby_llm, skip_on_ruby_llm_1: RUBY_LLM_2_ONLY do
    stub_json(:post, "#{OPENROUTER_API}/rerank",
              { model: "cohere/rerank-v3.5", results: [{ index: 1, relevance_score: 0.91 }],
                usage: { total_tokens: 1200, cost: 0.002 } })
    RubyLLM.rerank("ruby", %w[python ruby], model: "cohere/rerank-v3.5", provider: :openrouter,
                                            assume_model_exists: true)
  end

  define_case "ruby_llm bedrock chat stream: 1h and 5m cache writes from cacheDetails on a us profile",
              instrument: :ruby_llm, skip_on_ruby_llm_1: CONVERSE_STREAM_ON_RUBY_LLM_1 do
    stub_converse_stream(converse_usage(3000, 800, cache_read: 500, one_hour: 3000, five_minute: 1000))
    ruby_llm_chat("us.anthropic.claude-sonnet-4-5-20250929-v1:0", :bedrock, context: bedrock_context("us-east-1"))
      .ask("hi") { nil }
  end

  define_case "ruby_llm bedrock chat stream: cacheDetails split over with_caching's 1h TTL on a global profile",
              instrument: :ruby_llm, skip_on_ruby_llm_1: CONVERSE_STREAM_ON_RUBY_LLM_1 do
    stub_converse_stream(converse_usage(1200, 300, one_hour: 2000, five_minute: 1500))
    ruby_llm_chat("global.anthropic.claude-sonnet-4-5-20250929-v1:0", :bedrock, context: bedrock_context("sa-east-1"))
      .with_caching(ttl: "1h").ask("hi") { nil }
  end

  define_case "ruby_llm bedrock chat stream: GovCloud profile stays unpriced",
              instrument: :ruby_llm, skip_on_ruby_llm_1: CONVERSE_STREAM_ON_RUBY_LLM_1 do
    stub_converse_stream(converse_usage(3000, 800, cache_read: 500, one_hour: 3000, five_minute: 1000))
    ruby_llm_chat("us-gov.anthropic.claude-sonnet-4-5-20250929-v1:0", :bedrock,
                  context: bedrock_context("us-gov-west-1")).ask("hi") { nil }
  end

  define_case "ruby_llm bedrock chat: 1h and 5m cache writes from cacheDetails on an eu profile",
              instrument: :ruby_llm do
    stub_json(:post, %r{\Ahttps://bedrock-runtime\.eu-central-1\.amazonaws\.com/model/[^/]+/converse\z},
              { output: { message: { role: "assistant", content: [{ text: "hi" }] } }, stopReason: "end_turn",
                usage: converse_usage(2000, 400, cache_read: 6000, one_hour: 4000, five_minute: 1000),
                metrics: { latencyMs: 640 } })
    ruby_llm_chat("eu.anthropic.claude-haiku-4-5-20251001-v1:0", :bedrock, context: bedrock_context("eu-central-1"))
      .ask("hi")
  end
end
