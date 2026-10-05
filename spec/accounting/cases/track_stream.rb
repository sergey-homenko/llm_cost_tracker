# frozen_string_literal: true

module AccountingCases
  def realtime_response_done(keys)
    usage = { total_tokens: 1200, input_tokens: 900, output_tokens: 300,
              input_token_details: { text_tokens: 100, audio_tokens: 800, image_tokens: 0, cached_tokens: 640,
                                     cached_tokens_details: { text_tokens: 64, audio_tokens: 576, image_tokens: 0 } },
              output_token_details: { text_tokens: 60, audio_tokens: 240 } }
    event = { type: "response.done", event_id: "event_1",
              response: { id: "resp_rt1", object: "realtime.response", status: "completed", usage: usage } }
    keys == :string ? JSON.parse(JSON.generate(event)) : event
  end

  define_case "track_stream openai: string-keyed chunks with cached tokens" do
    LlmCostTracker.track_stream(provider: "openai", model: "gpt-4o") do |stream|
      stream.event({ "id" => "chatcmpl_ts1", "model" => "gpt-4o", "choices" => [{ "delta" => { "content" => "hi" } }] })
      stream.event({ "id" => "chatcmpl_ts1", "model" => "gpt-4o", "choices" => [],
                     "usage" => { "prompt_tokens" => 1000, "completion_tokens" => 200,
                                  "prompt_tokens_details" => { "cached_tokens" => 400 } } })
    end
  end

  define_case "track_stream openai: symbol-keyed chunks" do
    LlmCostTracker.track_stream(provider: "openai", model: "gpt-4o") do |stream|
      stream.event({ id: "chatcmpl_ts2", model: "gpt-4o", choices: [{ delta: { content: "hi" } }] })
      stream.event({ id: "chatcmpl_ts2", model: "gpt-4o", choices: [],
                     usage: { prompt_tokens: 1000, completion_tokens: 200 } })
    end
  end

  define_case "track_stream openai: symbol-keyed realtime response.done after session.created" do
    LlmCostTracker.track_stream(provider: "openai", model: "gpt-realtime") do |stream|
      stream.event({ type: "session.created", event_id: "e0", session: { id: "sess_1", model: "gpt-realtime" } },
                   type: "session.created")
      stream.event(realtime_response_done(:symbol), type: "response.done")
    end
  end

  define_case "track_stream openai: string-keyed realtime response.done" do
    LlmCostTracker.track_stream(provider: "openai", model: "gpt-realtime") do |stream|
      stream.event(realtime_response_done(:string), type: "response.done")
    end
  end

  define_case "track_stream openai: gpt-realtime-mini response.done without event type" do
    LlmCostTracker.track_stream(provider: "openai", model: "gpt-realtime-mini") do |stream|
      stream.event(realtime_response_done(:symbol))
    end
  end

  define_case "track_stream anthropic: explicit usage call" do
    LlmCostTracker.track_stream(provider: "anthropic", model: "claude-sonnet-4-5") do |stream|
      stream.usage(input_tokens: 1000, output_tokens: 300, cache_read_input_tokens: 500,
                   provider_response_id: "msg_ts3")
    end
  end

  define_case "track_stream anthropic: string-keyed events with cache writes growing" do
    start_usage = { "input_tokens" => 79, "cache_creation_input_tokens" => 2600,
                    "cache_creation" => { "ephemeral_5m_input_tokens" => 0, "ephemeral_1h_input_tokens" => 2600 },
                    "output_tokens" => 3 }
    delta_usage = { "cache_creation_input_tokens" => 7924, "cache_read_input_tokens" => 2600, "output_tokens" => 510 }
    LlmCostTracker.track_stream(provider: "anthropic", model: "claude-sonnet-4-6") do |stream|
      stream.event({ "type" => "message_start",
                     "message" => { "id" => "msg_ts4", "model" => "claude-sonnet-4-6", "usage" => start_usage } },
                   type: "message_start")
      stream.event({ "type" => "message_delta", "usage" => delta_usage }, type: "message_delta")
    end
  end

  define_case "track_stream anthropic: symbol-keyed events" do
    LlmCostTracker.track_stream(provider: "anthropic", model: "claude-sonnet-4-5") do |stream|
      stream.event({ type: "message_start",
                     message: { id: "msg_ts5", model: "claude-sonnet-4-5",
                                usage: { input_tokens: 500, output_tokens: 1 } } })
      stream.event({ type: "message_delta", usage: { output_tokens: 200 } })
    end
  end

  define_case "track_stream gemini: image prompt usage metadata" do
    LlmCostTracker.track_stream(provider: "gemini", model: "gemini-2.5-flash") do |stream|
      stream.event({ "usageMetadata" => { "promptTokenCount" => 1300, "candidatesTokenCount" => 200,
                                          "promptTokensDetails" => [{ "modality" => "TEXT", "tokenCount" => 10 },
                                                                    { "modality" => "IMAGE", "tokenCount" => 1290 }] },
                     "responseId" => "gts1" })
    end
  end

  define_case "track_stream openai: no events" do
    LlmCostTracker.track_stream(provider: "openai", model: "gpt-4o") { |_stream| nil }
  end

  define_case "track_stream openrouter: billed cost chunk" do
    LlmCostTracker.track_stream(provider: "openrouter", model: "openai/gpt-4o") do |stream|
      stream.event({ "id" => "gen-ts6", "model" => "openai/gpt-4o", "choices" => [],
                     "usage" => { "prompt_tokens" => 3000, "completion_tokens" => 500, "cost" => 0.0123,
                                  "is_byok" => false } })
    end
  end

  define_case "track_stream openai: block raises after the usage chunk" do
    expect do
      LlmCostTracker.track_stream(provider: "openai", model: "gpt-4o") do |stream|
        stream.event({ "id" => "chatcmpl_ts7", "model" => "gpt-4o", "choices" => [],
                       "usage" => { "prompt_tokens" => 100, "completion_tokens" => 10 } })
        raise IOError, "client disconnected"
      end
    end.to raise_error(IOError)
  end

  define_case "track_stream openai: more than 1 MB of logprobs" do
    LlmCostTracker.track_stream(provider: "openai", model: "gpt-4.1-mini") do |stream|
      400.times do |i|
        top = Array.new(20) { |r| { "token" => " w#{i}_#{r}", "logprob" => -1.0, "bytes" => [32, 119, 48, 49] } }
        logprobs = { "content" => [{ "token" => " w#{i}", "logprob" => -0.5, "top_logprobs" => top }] }
        stream.event({ "id" => "chatcmpl_ts8", "model" => "gpt-4.1-mini",
                       "choices" => [{ "delta" => { "content" => " w#{i}" }, "logprobs" => logprobs }] })
      end
      stream.event({ "id" => "chatcmpl_ts8", "model" => "gpt-4.1-mini", "choices" => [],
                     "usage" => { "prompt_tokens" => 50, "completion_tokens" => 400 } })
    end
  end

  define_case "track_stream anthropic: batch pricing mode" do
    LlmCostTracker.track_stream(provider: "anthropic", model: "claude-sonnet-4-5", pricing_mode: :batch) do |stream|
      stream.event({ "type" => "message_start",
                     "message" => { "id" => "msg_ts9", "usage" => { "input_tokens" => 1000, "output_tokens" => 1 } } })
      stream.event({ "type" => "message_delta", "usage" => { "output_tokens" => 100 } })
    end
  end

  define_case "track_stream openai: symbol-keyed responses events with a web search call" do
    LlmCostTracker.track_stream(provider: "openai", model: "gpt-4.1") do |stream|
      stream.event({ type: "response.output_item.done",
                     item: { type: "web_search_call", id: "ws_t1", status: "completed", action: { type: "search" } } })
      stream.event({ type: "response.completed",
                     response: { id: "resp_ts10", model: "gpt-4.1", usage: responses_usage(3000, 300) } })
    end
  end

  define_case "track_stream openai: logprobs-typed events ignored" do
    LlmCostTracker.track_stream(provider: "openai", model: "gpt-4o") do |stream|
      stream.event({ "type" => "logprobs.content.delta", "content" => [{ "token" => "x", "logprob" => -0.1 }] },
                   type: "logprobs.content.delta")
      stream.event({ "id" => "chatcmpl_lpt", "model" => "gpt-4o", "choices" => [],
                     "usage" => { "prompt_tokens" => 100, "completion_tokens" => 10 } },
                   type: "chunk")
    end
  end

  define_case "track_stream openai: usage under both snapshot and chunk keys" do
    LlmCostTracker.track_stream(provider: "openai", model: "gpt-4o") do |stream|
      stream.event({ "type" => "chunk",
                     "snapshot" => { "id" => "x", "usage" => { "prompt_tokens" => 999, "completion_tokens" => 1 } },
                     "chunk" => { "id" => "chatcmpl_snap", "model" => "gpt-4o", "choices" => [],
                                  "usage" => { "prompt_tokens" => 100, "completion_tokens" => 10 } } })
    end
  end

  define_case "track_stream azure openai: dated chunk model with cached tokens" do
    LlmCostTracker.track_stream(provider: "azure_openai", model: "gpt-4o") do |stream|
      stream.event({ "id" => "chatcmpl_az", "model" => "gpt-4o-2024-11-20", "choices" => [],
                     "usage" => { "prompt_tokens" => 2000, "completion_tokens" => 300,
                                  "prompt_tokens_details" => { "cached_tokens" => 1024 } } })
    end
  end

  define_case "track_stream openrouter: byok fee with upstream cost" do
    LlmCostTracker.track_stream(provider: "openrouter", model: "anthropic/claude-sonnet-4.5") do |stream|
      stream.event({ id: "gen-tsb", model: "anthropic/claude-sonnet-4.5", choices: [],
                     usage: { prompt_tokens: 3000, completion_tokens: 500, cost: 0.000825, is_byok: true,
                              cost_details: { upstream_inference_cost: 0.0165 } } })
    end
  end

  define_case "track_stream groq: flex service tier in the chunk" do
    LlmCostTracker.track_stream(provider: "groq", model: "openai/gpt-oss-120b") do |stream|
      stream.event({ "id" => "chatcmpl-tg", "model" => "openai/gpt-oss-120b", "service_tier" => "flex",
                     "choices" => [], "usage" => { "prompt_tokens" => 10_000, "completion_tokens" => 1000 } })
    end
  end

  define_case "track_stream mistral: usage in the final chunk" do
    LlmCostTracker.track_stream(provider: "mistral", model: "mistral-medium-latest") do |stream|
      stream.event({ "id" => "cmpl-tm", "model" => "mistral-medium-latest",
                     "choices" => [{ "delta" => { "content" => "hi" } }] })
      stream.event({ "id" => "cmpl-tm", "model" => "mistral-medium-latest", "choices" => [],
                     "usage" => { "prompt_tokens" => 4000, "completion_tokens" => 800, "total_tokens" => 4800 } })
    end
  end

  define_case "track_stream anthropic: fast speed on opus-5-5" do
    LlmCostTracker.track_stream(provider: "anthropic", model: "claude-opus-5-5") do |stream|
      usage = { "input_tokens" => 10_000, "output_tokens" => 1, "speed" => "fast" }
      stream.event({ "type" => "message_start",
                     "message" => { "id" => "msg_tsf", "model" => "claude-opus-5-5", "usage" => usage } })
      stream.event({ "type" => "message_delta", "usage" => { "output_tokens" => 1000 } })
    end
  end

  define_case "track_stream openai: 60 tool-call chunks of 28 KB before usage" do
    LlmCostTracker.track_stream(provider: "openai", model: "gpt-4o") do |stream|
      60.times { |i| stream.event(large_tool_call_chunk("chatcmpl_ovf", i)) }
      stream.event({ "id" => "chatcmpl_ovf", "model" => "gpt-4o", "choices" => [],
                     "usage" => { "prompt_tokens" => 100, "completion_tokens" => 10 } })
    end
  end

  define_case "track_stream gemini: cached audio" do
    response = gemini_response(model: "gemini-2.5-flash", id: "gs2", usage: gemini_cached_audio_usage(100))
    LlmCostTracker.track_stream(provider: "gemini", model: "gemini-2.5-flash") do |stream|
      stream.event(JSON.parse(JSON.generate(response)))
    end
  end

  define_case "track_stream anthropic: advisor iterations in message_delta" do
    LlmCostTracker.track_stream(provider: "anthropic", model: "claude-sonnet-5") do |stream|
      stream.event({ "type" => "message_start",
                     "message" => { "id" => "msg_adv5", "model" => "claude-sonnet-5",
                                    "usage" => { "input_tokens" => 1_760, "output_tokens" => 1 } } })
      stream.event(JSON.parse(JSON.generate({ type: "message_delta", usage: advisor_usage })))
    end
  end

  define_case "track_stream xai: billed cost_in_usd_ticks in the final chunk" do
    usage = xai_chat_usage(3000, 200, reasoning: 800, cached: 2000).merge(cost_in_usd_ticks: 90_000_000)
    LlmCostTracker.track_stream(provider: :xai, model: "grok-4.7") do |stream|
      stream.event(chat_chunk(id: "xai_b5", model: "grok-4.7", choices: [{ index: 0, delta: { content: "hi" } }]))
      stream.event(chat_chunk(id: "xai_b5", model: "grok-4.7", choices: [], usage: usage))
    end
  end
end
