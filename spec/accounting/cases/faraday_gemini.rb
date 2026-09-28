# frozen_string_literal: true

module AccountingCases
  BLOCKING_DAILY_BUDGET = lambda do |config|
    config.budgets.daily = 0.00001
    config.budgets.exceeded_behavior = :block_requests
  end

  def flash_interaction(id)
    interaction(id, "completed", usage: interaction_usage(input: 1000, output: 200), model: "gemini-2.5-flash")
  end

  define_case "faraday gemini generateContent: 2.5-flash text" do
    faraday_gemini("gemini-2.5-flash", gemini_usage(prompt: 1000, candidates: 300))
  end

  define_case "faraday gemini generateContent: cached content tokens" do
    faraday_gemini("gemini-2.5-flash", gemini_usage(prompt: 1000, candidates: 300, cached: 600,
                                                    cache_details: modalities(TEXT: 600)))
  end

  define_case "faraday gemini generateContent: 2.5-pro thoughts tokens" do
    faraday_gemini("gemini-2.5-pro", gemini_usage(prompt: 1000, candidates: 300, thoughts: 1200))
  end

  define_case "faraday gemini generateContent: 2.5-flash image prompt" do
    faraday_gemini("gemini-2.5-flash", gemini_usage(prompt: 1300, candidates: 200,
                                                    prompt_details: modalities(TEXT: 10, IMAGE: 1290)))
  end

  define_case "faraday gemini generateContent: 2.0-flash-lite audio prompt" do
    faraday_gemini("gemini-2.0-flash-lite", gemini_usage(prompt: 19_210, candidates: 500,
                                                         prompt_details: modalities(TEXT: 10, AUDIO: 19_200)))
  end

  define_case "faraday gemini generateContent: 3.8-flash ten minutes of audio" do
    faraday_gemini("gemini-3.8-flash", gemini_usage(prompt: 19_210, candidates: 1000,
                                                    prompt_details: modalities(TEXT: 10, AUDIO: 19_200)))
  end

  define_case "faraday gemini generateContent: video and audio prompt" do
    faraday_gemini("gemini-2.5-flash", gemini_usage(prompt: 20_000, candidates: 400,
                                                    prompt_details: modalities(TEXT: 100, VIDEO: 15_800, AUDIO: 4100)))
  end

  define_case "faraday gemini generateContent: document prompt" do
    faraday_gemini("gemini-3-flash-preview", gemini_usage(prompt: 5160, candidates: 400,
                                                          prompt_details: modalities(TEXT: 20, DOCUMENT: 5140)))
  end

  define_case "faraday gemini generateContent: 3.1-flash-lite pdf pages as image tokens" do
    faraday_gemini("gemini-3.1-flash-lite", gemini_usage(prompt: 2600, candidates: 100,
                                                         prompt_details: modalities(TEXT: 20, IMAGE: 2580)))
  end

  define_case "faraday gemini generateContent: tool use prompt tokens" do
    faraday_gemini("gemini-2.5-flash", gemini_usage(prompt: 1000, candidates: 300, tool_use: 2500,
                                                    tool_use_details: modalities(TEXT: 2500)))
  end

  define_case "faraday gemini generateContent: 2.5-flash grounding with three queries" do
    faraday_gemini("gemini-2.5-flash", gemini_usage(prompt: 1000, candidates: 300), grounding: %w[a b c])
  end

  define_case "faraday gemini generateContent: 3-flash-preview grounding with three queries" do
    faraday_gemini("gemini-3-flash-preview", gemini_usage(prompt: 1000, candidates: 300), grounding: %w[a b c])
  end

  define_case "faraday gemini generateContent: 2.5-pro long context with thoughts" do
    faraday_gemini("gemini-2.5-pro", gemini_usage(prompt: 250_000, candidates: 3000, thoughts: 2000))
  end

  define_case "faraday gemini generateContent: 2.5-pro long context with image and audio" do
    faraday_gemini("gemini-2.5-pro",
                   gemini_usage(prompt: 250_000, candidates: 3000,
                                prompt_details: modalities(TEXT: 200_000, IMAGE: 30_000, AUDIO: 20_000)))
  end

  define_case "faraday gemini generateContent: 3.1-pro-preview long context with cached tokens" do
    faraday_gemini("gemini-3.1-pro-preview", gemini_usage(prompt: 220_000, candidates: 3000, cached: 100_000,
                                                          cache_details: modalities(TEXT: 100_000)))
  end

  define_case "faraday gemini generateContent: priority service tier in usage metadata" do
    faraday_gemini("gemini-2.5-flash", gemini_usage(prompt: 1000, candidates: 300, service_tier: "priority",
                                                    prompt_details: modalities(TEXT: 500, IMAGE: 500)))
  end

  define_case "faraday gemini generateContent: flex service tier header" do
    faraday_gemini("gemini-2.5-flash", gemini_usage(prompt: 1000, candidates: 300,
                                                    prompt_details: modalities(TEXT: 500, AUDIO: 500)),
                   headers: { "x-gemini-service-tier" => "flex" })
  end

  define_case "faraday gemini generateContent: flex service tier requested" do
    faraday_gemini("gemini-2.5-flash-lite", gemini_usage(prompt: 1000, candidates: 300),
                   request: gemini_request(service_tier: "flex"))
  end

  define_case "faraday gemini generateContent: priority requested but not reported" do
    faraday_gemini("gemini-2.5-flash-lite", gemini_usage(prompt: 1000, candidates: 300),
                   request: gemini_request(serviceTier: "priority"))
  end

  define_case "faraday gemini generateContent: 2.5-flash-image image output" do
    faraday_gemini("gemini-2.5-flash-image",
                   gemini_usage(prompt: 12, candidates: 1290, candidate_details: modalities(IMAGE: 1290)),
                   parts: [{ inlineData: { mimeType: "image/png", data: "iVBORw0KGgo=" } }])
  end

  define_case "faraday gemini generateContent: 3-pro-image text and image output with image input" do
    faraday_gemini("gemini-3-pro-image",
                   gemini_usage(prompt: 580, candidates: 1320, thoughts: 200,
                                prompt_details: modalities(TEXT: 20, IMAGE: 560),
                                candidate_details: modalities(IMAGE: 1120, TEXT: 200)))
  end

  define_case "faraday gemini generateContent: 3.1-flash-image on the batch tier" do
    faraday_gemini("gemini-3.1-flash-image", gemini_usage(prompt: 12, candidates: 1120, service_tier: "batch",
                                                          candidate_details: modalities(IMAGE: 1120)))
  end

  define_case "faraday gemini generateContent: audio output" do
    faraday_gemini("gemini-2.5-flash",
                   gemini_usage(prompt: 100, candidates: 2000, candidate_details: modalities(AUDIO: 2000)))
  end

  define_case "faraday gemini generateContent: cached content with image tokens" do
    faraday_gemini("gemini-2.5-flash", gemini_usage(prompt: 3000, candidates: 100, cached: 2000,
                                                    prompt_details: modalities(TEXT: 1000, IMAGE: 2000),
                                                    cache_details: modalities(TEXT: 500, IMAGE: 1500)))
  end

  define_case "faraday gemini generateContent: unknown model" do
    faraday_gemini("gemini-9-ultra", gemini_usage(prompt: 100, candidates: 10))
  end

  define_case "faraday gemini stream: cumulative usage over crlf-delimited events" do
    chunks = [
      gemini_response(model: "gemini-2.5-flash", usage: gemini_usage(prompt: 1000, candidates: 5), id: "gs1"),
      gemini_response(model: "gemini-2.5-flash", usage: gemini_usage(prompt: 1000, candidates: 250, thoughts: 90),
                      id: "gs1")
    ]
    faraday_sse(gemini_url("gemini-2.5-flash", stream: true), gemini_request, sse(*chunks, crlf: true))
  end

  define_case "faraday gemini stream: grounding with two queries" do
    chunks = [
      gemini_response(model: "gemini-3-flash-preview", usage: gemini_usage(prompt: 1000, candidates: 5), id: "gs2"),
      gemini_response(model: "gemini-3-flash-preview", usage: gemini_usage(prompt: 1000, candidates: 250), id: "gs2",
                      grounding: %w[x y])
    ]
    faraday_sse(gemini_url("gemini-3-flash-preview", stream: true), gemini_request, sse(*chunks))
  end

  define_case "faraday gemini stream: image prompt read through an on_data callback" do
    usage = gemini_usage(prompt: 1300, candidates: 250, prompt_details: modalities(TEXT: 10, IMAGE: 1290))
    faraday_sse(gemini_url("gemini-2.5-flash-lite", stream: true), gemini_request,
                sse(gemini_response(model: "gemini-2.5-flash-lite", usage: usage, id: "gs3")), on_data: true)
  end

  define_case "faraday gemini stream: no usage metadata" do
    faraday_sse(gemini_url("gemini-2.5-flash", stream: true), gemini_request,
                sse(gemini_response(model: "gemini-2.5-flash", usage: nil, id: "gs4")))
  end

  define_case "faraday gemini generateContent: 2.0-flash image prompt" do
    faraday_gemini("gemini-2.0-flash", gemini_usage(prompt: 1300, candidates: 200,
                                                    prompt_details: modalities(TEXT: 10, IMAGE: 1290)))
  end

  define_case "faraday gemini generateContent: 3-pro-image-preview text and image output with thoughts" do
    faraday_gemini("gemini-3-pro-image-preview", gemini_usage(prompt: 20, candidates: 1170, thoughts: 300,
                                                              candidate_details: modalities(IMAGE: 1120, TEXT: 50)))
  end

  define_case "faraday gemini generateContent: 3.1-flash-lite image prompt with flex header" do
    faraday_gemini("gemini-3.1-flash-lite", gemini_usage(prompt: 2600, candidates: 100,
                                                         prompt_details: modalities(TEXT: 20, IMAGE: 2580)),
                   headers: { "x-gemini-service-tier" => "flex" })
  end

  define_case "faraday gemini generateContent: cached audio" do
    faraday_gemini("gemini-2.5-flash", gemini_usage(prompt: 20_000, candidates: 100, cached: 16_000,
                                                    prompt_details: modalities(TEXT: 1000, AUDIO: 19_000),
                                                    cache_details: modalities(AUDIO: 16_000)))
  end

  define_case "faraday gemini generateContent: cached text and audio" do
    faraday_gemini("gemini-2.5-flash", gemini_usage(prompt: 20_000, candidates: 100, cached: 16_000,
                                                    prompt_details: modalities(TEXT: 5000, AUDIO: 15_000),
                                                    cache_details: modalities(TEXT: 4000, AUDIO: 12_000)))
  end

  define_case "faraday gemini stream: cached audio" do
    faraday_sse(gemini_url("gemini-2.5-flash", stream: true), gemini_request,
                sse(gemini_response(model: "gemini-2.5-flash", id: "gs1", usage: gemini_cached_audio_usage(50))))
  end

  define_case "faraday gemini interactions: background interaction polled until completed" do
    faraday_json(GEMINI_INTERACTIONS, { model: "gemini-3.1-pro-preview", input: "long", background: true },
                 interaction("v1_bgR5", "in_progress"))
    stub_json_sequence(:get, "#{GEMINI_INTERACTIONS}/v1_bgR5", interaction("v1_bgR5", "in_progress"),
                       interaction("v1_bgR5", "completed",
                                   usage: interaction_usage(input: 20_000, output: 4000, thought: 6000)))
    3.times { faraday_request(:get, "#{GEMINI_INTERACTIONS}/v1_bgR5") }
  end

  define_case "faraday gemini interactions: completed on create, then retrieved" do
    faraday_json(GEMINI_INTERACTIONS, { model: "gemini-2.5-flash", input: "hi" }, flash_interaction("v1_cg7"))
    stub_json(:get, "#{GEMINI_INTERACTIONS}/v1_cg7", flash_interaction("v1_cg7"))
    faraday_request(:get, "#{GEMINI_INTERACTIONS}/v1_cg7")
  end

  define_case "faraday gemini interactions: delete records nothing" do
    stub_json(:delete, "#{GEMINI_INTERACTIONS}/v1_del", {})
    faraday_request(:delete, "#{GEMINI_INTERACTIONS}/v1_del")
  end

  define_case "faraday gemini interactions: two separate interactions" do
    stub_json_sequence(:post, GEMINI_INTERACTIONS, flash_interaction("v1_a"), flash_interaction("v1_b"))
    2.times { faraday_post(GEMINI_INTERACTIONS, { model: "gemini-2.5-flash", input: "hi" }) }
  end

  define_case "faraday gemini interactions: poll over a block_requests daily budget raises",
              configure: BLOCKING_DAILY_BUDGET do
    stub_json(:get, "#{GEMINI_INTERACTIONS}/v1_bb", flash_interaction("v1_bb"))
    expect { faraday_request(:get, "#{GEMINI_INTERACTIONS}/v1_bb") }.to raise_error(LlmCostTracker::BudgetExceededError)
  end

  define_case "faraday gemini interactions: resumed stream records nothing" do
    stub_sse(:get, "#{GEMINI_INTERACTIONS}/v1_rs?stream=true",
             sse(["interaction.completed", { interaction: flash_interaction("v1_rs"),
                                             event_type: "interaction.completed" }]))
    faraday_request(:get, "#{GEMINI_INTERACTIONS}/v1_rs?stream=true")
  end

  define_case "faraday gemini interactions: create and retrieve inside an application transaction" do
    stub_json(:post, GEMINI_INTERACTIONS, flash_interaction("v1_tx"))
    stub_json(:get, "#{GEMINI_INTERACTIONS}/v1_tx", flash_interaction("v1_tx"))
    LlmCostTracker::Call.transaction do
      faraday_post(GEMINI_INTERACTIONS, { model: "gemini-2.5-flash", input: "hi" })
      faraday_request(:get, "#{GEMINI_INTERACTIONS}/v1_tx")
      expect(LlmCostTracker::Call.count).to eq(1)
    end
  end
end
