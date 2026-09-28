# frozen_string_literal: true

require "llm_cost_tracker/pricing/backfill"

module AccountingCases
  CACHED_BUDGET_TOTALS = ->(config) { config.budgets.totals_source = :cache }
  CUSTOM_MODEL_OVERRIDES = lambda do |config|
    config.pricing.overrides = {
      "acme-model" => { "input" => 1.0, "output" => 2.0, "cached_input" => 0.1,
                        "_context_price_threshold_tokens" => 100_000,
                        "above_context_input" => 2.0, "above_context_output" => 4.0 },
      "openai/gpt-4o" => { "input" => 5.0, "output" => 20.0 }
    }
  end
  OPENROUTER_GPT_4O_OVERRIDE = lambda do |config|
    config.pricing.overrides = { "openrouter/openai/gpt-4o" => { "input" => 100.0, "output" => 100.0 } }
  end
  FLASH_WITHOUT_IMAGE_RATE = { "gemini/gemini-2.5-flash" => { "input" => 0.3, "output" => 2.5 } }.freeze
  FLASH_WITH_IMAGE_RATE = {
    "gemini/gemini-2.5-flash" => { "input" => 0.3, "output" => 2.5, "image_input" => 0.3 }
  }.freeze

  def reset_configuration(overrides:)
    LlmCostTrackerReset.call
    LlmCostTracker.configure do |config|
      config.ingestion.mode = :inline
      config.budgets.totals_source = :cache
      config.pricing.overrides = overrides
    end
  end

  define_case "async ingestion: faraday openai chat with cached tokens", async: true do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "gpt-4o", messages: [] },
                 chat_completion(id: "chatcmpl_as1", model: "gpt-4o", usage: chat_usage(1000, 200, cached: 400)))
  end

  define_case "async ingestion: faraday openrouter billed cost", async: true do
    faraday_json("#{OPENROUTER_API}/chat/completions", { model: "openai/gpt-4o", messages: [] },
                 chat_completion(id: "gen-as2", model: "openai/gpt-4o",
                                 usage: openrouter_usage(3000, 500, cost: 0.0123)))
  end

  define_case "async ingestion: faraday openrouter byok fee with upstream cost", async: true do
    faraday_json("#{OPENROUTER_API}/chat/completions", { model: "anthropic/claude-sonnet-4.5", messages: [] },
                 chat_completion(id: "gen-as3", model: "anthropic/claude-sonnet-4.5",
                                 usage: openrouter_usage(3000, 500, cost: 0.000825, byok: true, upstream: 0.0165)))
  end

  define_case "async ingestion: anthropic sdk stream with cache writes growing", instrument: :anthropic, async: true do
    start = { input_tokens: 79, cache_creation_input_tokens: 2600, cache_read_input_tokens: 0,
              cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: 2600 }, output_tokens: 3 }
    delta = { input_tokens: 79, cache_creation_input_tokens: 7924, cache_read_input_tokens: 2600, output_tokens: 510,
              server_tool_use: { web_search_requests: 1 } }
    stub_sse(:post, ANTHROPIC_MESSAGES,
             anthropic_stream_body(id: "msg_as4", model: "claude-sonnet-4-6", start_usage: start, delta_usage: delta))
    anthropic_client.messages.stream(**anthropic_request("claude-sonnet-4-6")).each { |_| nil }
  end

  define_case "async ingestion: openai sdk responses image generation call", instrument: :openai, async: true do
    output = [{ type: "image_generation_call", id: "ig_as5", status: "completed", result: "iVBORw0KGgo=" }]
    stub_json(:post, "#{OPENAI_API}/responses",
              responses_object(id: "resp_as5", model: "gpt-5.5", usage: responses_usage(2000, 200), output: output))
    openai_client.responses.create(model: "gpt-5.5", input: "draw", tools: [{ type: :image_generation }])
  end

  define_case "async ingestion: openai sdk whisper-1 duration usage", instrument: :openai, async: true do
    stub_json(:post, "#{OPENAI_API}/audio/transcriptions", { text: "hello", usage: { type: "duration", seconds: 61 } })
    openai_client.audio.transcriptions.create(file: audio_io, model: "whisper-1")
  end

  define_case "async ingestion: faraday gemini image prompt", async: true do
    faraday_gemini("gemini-2.5-flash", gemini_usage(prompt: 1300, candidates: 200,
                                                    prompt_details: modalities(TEXT: 10, IMAGE: 1290)))
  end

  define_case "async ingestion: openai batch embeddings", instrument: :openai, async: true do
    body = { object: "list", data: [], model: "text-embedding-3-small",
             usage: { prompt_tokens: 50_000, total_tokens: 50_000 } }
    stub_openai_batch(host: "api.openai.com", batch_id: "batch_as8", status: "completed", endpoint: "/v1/embeddings",
                      lines: [openai_batch_line("batch_req_as8a", "e1", body),
                              openai_batch_line("batch_req_as8b", "e2", body)])
    openai_client.batches.retrieve("batch_as8")
  end

  define_case "async ingestion: faraday openai background response polled until completed", async: true do
    faraday_json("#{OPENAI_API}/responses", { model: "o3-pro", input: "hi", background: true },
                 background_response("resp_bgF2", "queued"))
    stub_background_polls(OPENAI_API, "resp_bgF2")
    3.times { faraday_request(:get, "#{OPENAI_API}/responses/resp_bgF2") }
  end

  define_case "async ingestion: openai sdk background stream completed, then retrieved",
              instrument: :openai, async: true do
    stub_sse(:post, "#{OPENAI_API}/responses", background_stream_body("resp_bgS2"))
    stub_json(:get, "#{OPENAI_API}/responses/resp_bgS2",
              background_response("resp_bgS2", "completed", usage: responses_usage(1000, 500)))
    client = openai_client
    client.responses.stream_raw(model: "o3-pro", input: "hi", background: true).each { nil }
    client.responses.retrieve("resp_bgS2")
  end

  define_case "async ingestion: faraday anthropic advisor iterations", async: true do
    faraday_json(ANTHROPIC_MESSAGES, anthropic_request("claude-sonnet-5"),
                 anthropic_message(id: "msg_adv6", model: "claude-sonnet-5", usage: advisor_usage))
  end

  define_case "async ingestion: faraday gemini background interaction polled until completed", async: true do
    faraday_json(GEMINI_INTERACTIONS, { model: "gemini-3.1-pro-preview", input: "long", background: true },
                 interaction("v1_bgR6", "in_progress"))
    stub_json(:get, "#{GEMINI_INTERACTIONS}/v1_bgR6",
              interaction("v1_bgR6", "completed", usage: interaction_usage(input: 20_000, output: 4000, thought: 6000)))
    3.times { faraday_request(:get, "#{GEMINI_INTERACTIONS}/v1_bgR6") }
  end

  define_case "cached budget totals: faraday openai chat", configure: CACHED_BUDGET_TOTALS do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "gpt-4o", messages: [] },
                 chat_completion(id: "chatcmpl_ru1", model: "gpt-4o", usage: chat_usage(1000, 200)))
  end

  define_case "cached budget totals: faraday openrouter billed cost", configure: CACHED_BUDGET_TOTALS do
    faraday_json("#{OPENROUTER_API}/chat/completions", { model: "openai/gpt-4o", messages: [] },
                 chat_completion(id: "gen-ru2", model: "openai/gpt-4o",
                                 usage: openrouter_usage(3000, 500, cost: 0.0123)))
  end

  define_case "cached budget totals: faraday openai unknown model", configure: CACHED_BUDGET_TOTALS do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "gpt-9-imaginary", messages: [] },
                 chat_completion(id: "chatcmpl_ru3", model: "gpt-9-imaginary", usage: chat_usage(100, 10)))
  end

  define_case "cached budget totals: track across three providers", configure: CACHED_BUDGET_TOTALS do
    LlmCostTracker.track(provider: "openai", model: "gpt-4o", tokens: { input_tokens: 1000, output_tokens: 200 })
    LlmCostTracker.track(provider: "anthropic", model: "claude-sonnet-4-5",
                         tokens: { input_tokens: 1000, output_tokens: 200 })
    LlmCostTracker.track(provider: "gemini", model: "gemini-2.5-flash",
                         tokens: { input_tokens: 100, image_input_tokens: 1290, output_tokens: 20 })
  end

  define_case "cached budget totals: async faraday openrouter billed cost",
              configure: CACHED_BUDGET_TOTALS, async: true do
    faraday_json("#{OPENROUTER_API}/chat/completions", { model: "openai/gpt-4o", messages: [] },
                 chat_completion(id: "gen-ru5", model: "openai/gpt-4o",
                                 usage: openrouter_usage(3000, 500, cost: 0.0123)))
  end

  define_case "cached budget totals: anthropic batch with us inference geo",
              instrument: :anthropic, configure: CACHED_BUDGET_TOTALS do
    usage = { input_tokens: 1000, output_tokens: 500, service_tier: "batch", inference_geo: "us" }
    message = anthropic_message(id: "msg_ru6", model: "claude-sonnet-4-6", content: [], usage: usage)
    stub_anthropic_batch("msgbatch_ru6", [anthropic_batch_result("r1", message)])
    anthropic_client.messages.batches.results_streaming("msgbatch_ru6").each { |_| nil }
  end

  define_case "tags: symbol and string keys on track" do
    LlmCostTracker.track(provider: "openai", model: "gpt-4o", tokens: { input_tokens: 10, output_tokens: 5 },
                         tags: { :feature => "a", "feature" => "b", :team => "x" })
  end

  define_case "tags: with_tags context around track tags" do
    LlmCostTracker.with_tags(feature: "ctx", env: "prod") do
      LlmCostTracker.track(provider: "openai", model: "gpt-4o", tokens: { input_tokens: 10, output_tokens: 5 },
                           tags: { "feature" => "call" })
    end
  end

  define_case "tags: symbol and string keys on track_stream" do
    LlmCostTracker.track_stream(provider: "openai", model: "gpt-4o", tags: { :user => 1, "user" => 2 }) do |stream|
      stream.usage(input_tokens: 10, output_tokens: 5)
    end
  end

  define_case "pricing overrides: custom model below its context threshold", configure: CUSTOM_MODEL_OVERRIDES do
    LlmCostTracker.track(provider: "openai", model: "acme-model",
                         tokens: { input_tokens: 50_000, cache_read_input_tokens: 10_000, output_tokens: 1000 })
  end

  define_case "pricing overrides: custom model above its context threshold", configure: CUSTOM_MODEL_OVERRIDES do
    LlmCostTracker.track(provider: "openai", model: "acme-model",
                         tokens: { input_tokens: 150_000, cache_read_input_tokens: 10_000, output_tokens: 1000 })
  end

  define_case "pricing overrides: listed model through faraday", configure: CUSTOM_MODEL_OVERRIDES do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "gpt-4o", messages: [] },
                 chat_completion(id: "chatcmpl_ov3", model: "gpt-4o", usage: chat_usage(1000, 200, cached: 500)))
  end

  define_case "pricing overrides: openrouter billed cost against an override", configure: OPENROUTER_GPT_4O_OVERRIDE do
    faraday_json("#{OPENROUTER_API}/chat/completions", { model: "openai/gpt-4o", messages: [] },
                 chat_completion(id: "gen-ov4", model: "openai/gpt-4o",
                                 usage: openrouter_usage(3000, 500, cost: 0.0123)))
  end

  define_case "backfill: partial call after an image rate is added" do
    reset_configuration(overrides: FLASH_WITHOUT_IMAGE_RATE)
    LlmCostTracker.track(provider: "gemini", model: "gemini-2.5-flash",
                         tokens: { input_tokens: 100, image_input_tokens: 1290, output_tokens: 20 })
    reset_configuration(overrides: FLASH_WITH_IMAGE_RATE)
    LlmCostTracker::Pricing::Backfill.call
  end

  define_case "backfill: partial call after the input rate changes and an image rate is added" do
    reset_configuration(overrides: FLASH_WITHOUT_IMAGE_RATE)
    LlmCostTracker.track(provider: "gemini", model: "gemini-2.5-flash",
                         tokens: { input_tokens: 100, image_input_tokens: 1290, output_tokens: 20 })
    reset_configuration(
      overrides: { "gemini/gemini-2.5-flash" => { "input" => 0.5, "output" => 2.5, "image_input" => 0.5 } }
    )
    LlmCostTracker::Pricing::Backfill.call
  end

  define_case "backfill: unknown model priced by a later override" do
    reset_configuration(overrides: {})
    LlmCostTracker.track(provider: "openai", model: "acme-late-model",
                         tokens: { input_tokens: 1000, output_tokens: 100 })
    reset_configuration(overrides: { "openai/acme-late-model" => { "input" => 1.0, "output" => 2.0 } })
    LlmCostTracker::Pricing::Backfill.call
  end

  define_case "backfill: stream row with unknown usage" do
    reset_configuration(overrides: {})
    LlmCostTracker.track_stream(provider: "openai", model: "acme-late-model") { |_stream| nil }
    reset_configuration(overrides: { "openai/acme-late-model" => { "input" => 1.0, "output" => 2.0 } })
    LlmCostTracker::Pricing::Backfill.call
  end

  define_case "backfill: complete call left unchanged" do
    reset_configuration(overrides: {})
    LlmCostTracker.track(provider: "openai", model: "gpt-4o", tokens: { input_tokens: 1000, output_tokens: 100 })
    reset_configuration(overrides: { "openai/gpt-4o" => { "input" => 100.0, "output" => 100.0 } })
    LlmCostTracker::Pricing::Backfill.call
  end
end
