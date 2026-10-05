# frozen_string_literal: true

module AccountingCases
  define_case "faraday openai chat: gpt-4o dated snapshot with plain usage" do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "gpt-4o", messages: [{ role: "user", content: "hi" }] },
                 chat_completion(id: "chatcmpl_fa1", model: "gpt-4o-2024-08-06", usage: chat_usage(1000, 200)))
  end

  define_case "faraday openai chat: gpt-4o with cached prompt tokens" do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "gpt-4o", messages: [] },
                 chat_completion(id: "chatcmpl_fa2", model: "gpt-4o", usage: chat_usage(1000, 200, cached: 600)))
  end

  define_case "faraday openai chat: o3 dated snapshot with reasoning tokens" do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "o3", messages: [] },
                 chat_completion(id: "chatcmpl_fa3", model: "o3-2025-04-16",
                                 usage: chat_usage(2000, 500, reasoning: 150)))
  end

  define_case "faraday openai chat: o3 served on flex with cached tokens" do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "o3", service_tier: "flex", messages: [] },
                 chat_completion(id: "chatcmpl_fa4", model: "o3", usage: chat_usage(2000, 500, cached: 1000),
                                 service_tier: "flex"))
  end

  define_case "faraday openai chat: gpt-5.4 served on priority" do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "gpt-5.4", service_tier: "priority", messages: [] },
                 chat_completion(id: "chatcmpl_fa5", model: "gpt-5.4", usage: chat_usage(10_000, 1000),
                                 service_tier: "priority"))
  end

  define_case "faraday openai chat: gpt-4o served on the scale tier" do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "gpt-4o", messages: [] },
                 chat_completion(id: "chatcmpl_fa6", model: "gpt-4o", usage: chat_usage(1000, 100),
                                 service_tier: "scale"))
  end

  define_case "faraday openai chat: priority requested but default served" do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "gpt-5.5", service_tier: "priority", messages: [] },
                 chat_completion(id: "chatcmpl_fa7", model: "gpt-5.5", usage: chat_usage(10_000, 2000),
                                 service_tier: "default"))
  end

  define_case "faraday openai chat: gpt-audio audio input and output tokens" do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "gpt-audio", messages: [] },
                 chat_completion(id: "chatcmpl_fa8", model: "gpt-audio",
                                 usage: chat_usage(1200, 900, audio_in: 1000, audio_out: 800)))
  end

  define_case "faraday openai chat: gpt-5-search-api answer with a url citation" do
    citation = { url: "https://x.test", title: "x", start_index: 0, end_index: 2 }
    faraday_json("#{OPENAI_API}/chat/completions", { model: "gpt-5-search-api", messages: [] },
                 chat_completion(id: "chatcmpl_fa9", model: "gpt-5-search-api-2025-10-14", usage: chat_usage(1000, 500),
                                 annotations: [{ type: "url_citation", url_citation: citation }]))
  end

  define_case "faraday openai chat: gpt-4o-search-preview without annotations" do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "gpt-4o-search-preview", messages: [] },
                 chat_completion(id: "chatcmpl_fa10", model: "gpt-4o-search-preview", usage: chat_usage(500, 100)))
  end

  define_case "faraday openai chat: gpt-4o answer with a url citation" do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "gpt-4o", messages: [] },
                 chat_completion(id: "chatcmpl_fa11", model: "gpt-4o", usage: chat_usage(500, 100),
                                 annotations: [{ type: "url_citation",
                                                 url_citation: { url: "https://x.test", title: "x" } }]))
  end

  define_case "faraday openai chat: chat-latest with cached tokens" do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "chat-latest", messages: [] },
                 chat_completion(id: "chatcmpl_fa12", model: "chat-latest", usage: chat_usage(3000, 700, cached: 1000)))
  end

  define_case "faraday openai chat: gpt-5.6-cyber with reasoning tokens" do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "gpt-5.6-cyber", messages: [] },
                 chat_completion(id: "chatcmpl_fa13", model: "gpt-5.6-cyber",
                                 usage: chat_usage(3000, 700, reasoning: 300)))
  end

  define_case "faraday openai responses: gpt-rosalind-research with cached and reasoning tokens" do
    faraday_json("#{OPENAI_API}/responses", { model: "gpt-rosalind-research", input: "hi" },
                 responses_object(id: "resp_fa14", model: "gpt-rosalind-research",
                                  usage: responses_usage(5000, 2000, cached: 1000, reasoning: 1500)))
  end

  define_case "faraday openai chat: unknown model" do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "gpt-9-imaginary", messages: [] },
                 chat_completion(id: "chatcmpl_fa15", model: "gpt-9-imaginary", usage: chat_usage(100, 10)))
  end

  define_case "faraday openai chat: 429 error response records nothing" do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "gpt-4o", messages: [] },
                 { error: { message: "rate", type: "rate_limit" } }, status: 429)
  end

  define_case "faraday openai responses: gpt-5.5 dated snapshot with cached and reasoning tokens" do
    faraday_json("#{OPENAI_API}/responses", { model: "gpt-5.5", input: "hi" },
                 responses_object(id: "resp_fa1", model: "gpt-5.5-2026-04-23",
                                  usage: responses_usage(5000, 800, cached: 2000, reasoning: 300)))
  end

  define_case "faraday openai responses: gpt-5.4 long context with cached tokens" do
    faraday_json("#{OPENAI_API}/responses", { model: "gpt-5.4", input: "hi" },
                 responses_object(id: "resp_fa2", model: "gpt-5.4",
                                  usage: responses_usage(300_000, 5000, cached: 100_000)))
  end

  define_case "faraday openai responses: gpt-5.5-pro long context with reasoning tokens" do
    faraday_json("#{OPENAI_API}/responses", { model: "gpt-5.5-pro", input: "hi" },
                 responses_object(id: "resp_fa3", model: "gpt-5.5-pro",
                                  usage: responses_usage(300_000, 10_000, reasoning: 5000)))
  end

  define_case "faraday openai responses: gpt-5.5-pro below the long-context threshold" do
    faraday_json("#{OPENAI_API}/responses", { model: "gpt-5.5-pro", input: "hi" },
                 responses_object(id: "resp_fa4", model: "gpt-5.5-pro", usage: responses_usage(100_000, 10_000)))
  end

  define_case "faraday openai responses: gpt-5.5-pro long context on flex" do
    faraday_json("#{OPENAI_API}/responses", { model: "gpt-5.5-pro", input: "hi", service_tier: "flex" },
                 responses_object(id: "resp_fa5", model: "gpt-5.5-pro", usage: responses_usage(300_000, 10_000),
                                  service_tier: "flex"))
  end

  define_case "faraday openai responses: gpt-5.4 long context on flex with cached tokens" do
    faraday_json("#{OPENAI_API}/responses", { model: "gpt-5.4", input: "hi", service_tier: "flex" },
                 responses_object(id: "resp_fa6", model: "gpt-5.4",
                                  usage: responses_usage(300_000, 2000, cached: 200_000), service_tier: "flex"))
  end

  define_case "faraday openai responses: gpt-6-astra on ultrafast with cached and cache-write tokens" do
    usage = responses_usage(20_000, 1000, cached: 5000)
    usage[:input_tokens_details][:cache_write_tokens] = 2000
    faraday_json("#{OPENAI_API}/responses", { model: "gpt-6-astra", input: "hi", service_tier: "ultrafast" },
                 responses_object(id: "resp_fa15", model: "gpt-6-astra", usage: usage, service_tier: "ultrafast"))
  end

  define_case "faraday openai responses: web search, file search and code interpreter calls" do
    output = [
      { type: "web_search_call", id: "ws_1", status: "completed", action: { type: "search", query: "q" } },
      { type: "web_search_call", id: "ws_2", status: "completed", action: { type: "open_page", url: "https://x" } },
      { type: "file_search_call", id: "fs_1", status: "completed", queries: ["q"], results: nil },
      { type: "code_interpreter_call", id: "ci_1", status: "completed", container_id: "cntr_42", code: "1",
        outputs: [] },
      { type: "code_interpreter_call", id: "ci_2", status: "completed", container_id: "cntr_42", code: "2",
        outputs: [] },
      output_message("fa7")
    ]
    faraday_json("#{OPENAI_API}/responses", { model: "gpt-4.1", input: "hi", tools: [{ type: "web_search" }] },
                 responses_object(id: "resp_fa7", model: "gpt-4.1", usage: responses_usage(3000, 400), output: output))
  end

  define_case "faraday openai responses: web_search_preview call on reasoning o4-mini" do
    output = [{ type: "web_search_call", id: "ws_p1", status: "completed", action: { type: "search" } },
              output_message("fa8")]
    faraday_json("#{OPENAI_API}/responses", { model: "o4-mini", input: "hi", tools: [{ type: "web_search_preview" }] },
                 responses_object(id: "resp_fa8", model: "o4-mini", usage: responses_usage(3000, 400, reasoning: 200),
                                  output: output))
  end

  define_case "faraday openai responses: web_search_preview call on non-reasoning gpt-4.1" do
    output = [{ type: "web_search_call", id: "ws_p2", status: "completed", action: { type: "search" } },
              output_message("fa9")]
    faraday_json("#{OPENAI_API}/responses", { model: "gpt-4.1", input: "hi", tools: [{ type: "web_search_preview" }] },
                 responses_object(id: "resp_fa9", model: "gpt-4.1", usage: responses_usage(3000, 400), output: output))
  end

  define_case "faraday openai responses: completed image generation call" do
    output = [{ type: "image_generation_call", id: "ig_1", status: "completed", result: "iVBORw0KGgo=" },
              output_message("fa10")]
    faraday_json("#{OPENAI_API}/responses", { model: "gpt-5.5", input: "draw", tools: [{ type: "image_generation" }] },
                 responses_object(id: "resp_fa10", model: "gpt-5.5", usage: responses_usage(2000, 200), output: output))
  end

  define_case "faraday openai responses: failed image generation call" do
    output = [{ type: "image_generation_call", id: "ig_2", status: "failed", result: nil }, output_message("fa11")]
    faraday_json("#{OPENAI_API}/responses", { model: "gpt-5.5", input: "draw", tools: [{ type: "image_generation" }] },
                 responses_object(id: "resp_fa11", model: "gpt-5.5", usage: responses_usage(2000, 200), output: output))
  end

  define_case "faraday openai responses: gpt-realtime usage with audio and cached token details" do
    usage = { total_tokens: 1200, input_tokens: 900, output_tokens: 300,
              input_token_details: { text_tokens: 100, audio_tokens: 800, image_tokens: 0, cached_tokens: 640,
                                     cached_tokens_details: { text_tokens: 64, audio_tokens: 576, image_tokens: 0 } },
              output_token_details: { text_tokens: 60, audio_tokens: 240 } }
    faraday_json("#{OPENAI_API}/responses", { model: "gpt-realtime", input: "hi" },
                 responses_object(id: "resp_fa12", model: "gpt-realtime", usage: usage))
  end

  define_case "faraday openai embeddings: text-embedding-3-small" do
    faraday_json("#{OPENAI_API}/embeddings", { model: "text-embedding-3-small", input: %w[a b] },
                 { object: "list", data: [{ object: "embedding", index: 0, embedding: [0.1] }],
                   model: "text-embedding-3-small", usage: { prompt_tokens: 12_000, total_tokens: 12_000 } })
  end

  define_case "faraday openai embeddings: text-embedding-ada-002 reported as text-embedding-ada-002-v2" do
    faraday_json("#{OPENAI_API}/embeddings", { model: "text-embedding-ada-002", input: "a" },
                 { object: "list", data: [{ object: "embedding", index: 0, embedding: [0.1] }],
                   model: "text-embedding-ada-002-v2", usage: { prompt_tokens: 12_000, total_tokens: 12_000 } })
  end

  define_case "faraday openai images: gpt-image-1 generation with text and image input" do
    faraday_json("#{OPENAI_API}/images/generations", { model: "gpt-image-1", prompt: "a cat" },
                 { created: 1, data: [{ b64_json: "iVBORw0KGgo=" }],
                   usage: { input_tokens: 60, output_tokens: 4160, total_tokens: 4220,
                            input_tokens_details: { text_tokens: 50, image_tokens: 10 } } })
  end

  define_case "faraday openai images: gpt-image-2.5-sunburst generation" do
    faraday_json("#{OPENAI_API}/images/generations", { model: "gpt-image-2.5-sunburst", prompt: "a cat" },
                 { created: 1, data: [{ b64_json: "iVBORw0KGgo=" }],
                   usage: { input_tokens: 50, output_tokens: 1056, total_tokens: 1106,
                            input_tokens_details: { text_tokens: 50, image_tokens: 0 } } })
  end

  define_case "faraday openai images: gpt-image-2.5-flare edit with image input and output details" do
    faraday_json("#{OPENAI_API}/images/edits", { model: "gpt-image-2.5-flare", prompt: "blue" },
                 { created: 1, data: [{ b64_json: "iVBORw0KGgo=" }],
                   usage: { input_tokens: 400, output_tokens: 1056, total_tokens: 1456,
                            input_tokens_details: { text_tokens: 20, image_tokens: 380 },
                            output_tokens_details: { text_tokens: 0, image_tokens: 1056 } } })
  end

  define_case "faraday openai transcription: gpt-4o-transcribe token usage" do
    faraday_json("#{OPENAI_API}/audio/transcriptions", { model: "gpt-4o-transcribe" },
                 { text: "hi", usage: { type: "tokens", input_tokens: 1200, output_tokens: 300, total_tokens: 1500,
                                        input_token_details: { audio_tokens: 1150, text_tokens: 50 } } })
  end

  define_case "faraday openai transcription: whisper-1 duration usage" do
    faraday_json("#{OPENAI_API}/audio/transcriptions", { model: "whisper-1" },
                 { text: "hi", usage: { type: "duration", seconds: 125.5 } })
  end

  define_case "faraday openai transcription: gpt-transcribe duration usage" do
    faraday_json("#{OPENAI_API}/audio/transcriptions", { model: "gpt-transcribe" },
                 { text: "hi", usage: { type: "duration", seconds: 600 } })
  end

  define_case "faraday openai moderation: omni-moderation-latest free" do
    faraday_json("#{OPENAI_API}/moderations", { model: "omni-moderation-latest", input: "x" },
                 { id: "modr_fa", model: "omni-moderation-latest", results: [] })
  end

  define_case "faraday openai chat: gpt-5.4 on the eu host with cached tokens" do
    faraday_json("https://eu.api.openai.com/v1/chat/completions", { model: "gpt-5.4", messages: [] },
                 chat_completion(id: "chatcmpl_eu", model: "gpt-5.4", usage: chat_usage(10_000, 1000, cached: 2000)))
  end

  define_case "faraday openai chat: gpt-4o on the us host" do
    faraday_json("https://us.api.openai.com/v1/chat/completions", { model: "gpt-4o", messages: [] },
                 chat_completion(id: "chatcmpl_us", model: "gpt-4o", usage: chat_usage(10_000, 1000)))
  end

  define_case "faraday openai responses: gpt-5.5 priority on the us host" do
    faraday_json("https://us.api.openai.com/v1/responses", { model: "gpt-5.5", input: "x", service_tier: "priority" },
                 responses_object(id: "resp_uspr", model: "gpt-5.5", usage: responses_usage(10_000, 1000),
                                  service_tier: "priority"))
  end

  define_case "faraday openai chat stream: usage chunk with cached tokens" do
    faraday_sse("#{OPENAI_API}/chat/completions", { model: "gpt-4o", stream: true, messages: [] },
                chat_stream_body(id: "chatcmpl_fs1", model: "gpt-4o", usage: chat_usage(1000, 200, cached: 400)))
  end

  define_case "faraday openai chat stream: read through an on_data callback" do
    faraday_sse("#{OPENAI_API}/chat/completions", { model: "gpt-4o", stream: true, messages: [] },
                chat_stream_body(id: "chatcmpl_fs2", model: "gpt-4o", usage: chat_usage(1000, 200)), on_data: true)
  end

  define_case "faraday openai chat stream: no usage chunk" do
    faraday_sse("#{OPENAI_API}/chat/completions", { model: "gpt-4o", stream: true, messages: [] },
                chat_stream_body(id: "chatcmpl_fs3", model: "gpt-4o", usage: nil))
  end

  define_case "faraday openai chat stream: priority requested but default served" do
    faraday_sse("#{OPENAI_API}/chat/completions",
                { model: "gpt-5.5", stream: true, service_tier: "priority", messages: [] },
                chat_stream_body(id: "chatcmpl_fs4", model: "gpt-5.5", service_tier: "default",
                                 usage: chat_usage(10_000, 2000)))
  end

  define_case "faraday openai chat stream: gpt-5-search-api dated snapshot" do
    faraday_sse("#{OPENAI_API}/chat/completions", { model: "gpt-5-search-api", stream: true, messages: [] },
                chat_stream_body(id: "chatcmpl_fs5", model: "gpt-5-search-api-2025-10-14",
                                 usage: chat_usage(1000, 500)))
  end

  define_case "faraday openai chat stream: url citation in a delta" do
    faraday_sse("#{OPENAI_API}/chat/completions", { model: "gpt-4o", stream: true, messages: [] },
                chat_stream_body(id: "chatcmpl_fs6", model: "gpt-4o", usage: chat_usage(1000, 500),
                                 delta_annotations: [{ type: "url_citation",
                                                       url_citation: { url: "https://x", title: "x" } }]))
  end

  define_case "faraday openai chat stream: 1.5 MB of logprobs before the usage chunk" do
    base = { id: "chatcmpl_fs7", object: "chat.completion.chunk", created: 1, model: "gpt-4.1-mini" }
    chunks = Array.new(400) do |i|
      top = Array.new(20) { |r| { token: " w#{i}_#{r}", logprob: -1.0 - r, bytes: [32, 119] } }
      entry = { token: " w#{i}", logprob: -0.5, bytes: [32, 119], top_logprobs: top }
      choice = { index: 0, delta: { content: " w#{i}" }, logprobs: { content: [entry] }, finish_reason: nil }
      base.merge(choices: [choice])
    end
    faraday_sse("#{OPENAI_API}/chat/completions",
                { model: "gpt-4.1-mini", stream: true, logprobs: true, top_logprobs: 20, messages: [] },
                sse(*chunks, base.merge(choices: [], usage: chat_usage(50, 400)), done: true))
  end

  define_case "faraday openai responses stream: web search call with cached tokens" do
    output = [{ type: "web_search_call", id: "ws_s1", status: "completed", action: { type: "search" } },
              output_message("fs8")]
    faraday_sse("#{OPENAI_API}/responses",
                { model: "gpt-4.1", stream: true, input: "x", tools: [{ type: "web_search" }] },
                responses_stream_body(id: "resp_fs8", model: "gpt-4.1", usage: responses_usage(3000, 300, cached: 1000),
                                      output: output))
  end

  define_case "faraday openai responses stream: image generation call" do
    output = [{ type: "image_generation_call", id: "ig_s1", status: "completed", result: "iVBORw0KGgo=" },
              output_message("fs9")]
    faraday_sse("#{OPENAI_API}/responses",
                { model: "gpt-5.5", stream: true, input: "x", tools: [{ type: "image_generation" }] },
                responses_stream_body(id: "resp_fs9", model: "gpt-5.5", usage: responses_usage(2000, 200),
                                      output: output))
  end

  define_case "faraday openai responses stream: o3 served on flex" do
    faraday_sse("#{OPENAI_API}/responses", { model: "o3", stream: true, input: "x", service_tier: "flex" },
                responses_stream_body(id: "resp_fs10", model: "o3",
                                      usage: responses_usage(20_000, 4000, reasoning: 3000), service_tier: "flex"))
  end

  define_case "faraday openai responses stream: gpt-5.5-pro long context" do
    faraday_sse("#{OPENAI_API}/responses", { model: "gpt-5.5-pro", stream: true, input: "x" },
                responses_stream_body(id: "resp_fs11", model: "gpt-5.5-pro", usage: responses_usage(280_000, 4000)))
  end

  define_case "faraday azure openai chat: deployment url with a dated response model" do
    faraday_json("#{AZURE_OPENAI}/deployments/gpt4o-prod/chat/completions?api-version=2024-10-21", { messages: [] },
                 chat_completion(id: "chatcmpl_az1", model: "gpt-4o-2024-11-20",
                                 usage: chat_usage(2000, 300, cached: 1024),
                                 extra: { prompt_filter_results: [] }))
  end

  define_case "faraday azure openai chat: deployment url with a response without model" do
    body = chat_completion(id: "chatcmpl_az2", model: "x", usage: chat_usage(2000, 300)).except(:model)
    faraday_json("#{AZURE_OPENAI}/deployments/gpt-4o/chat/completions?api-version=2024-10-21", { messages: [] }, body)
  end

  define_case "faraday azure openai responses: v1 url" do
    faraday_json("#{AZURE_OPENAI}/v1/responses", { model: "gpt-4.1", input: "x" },
                 responses_object(id: "resp_az3", model: "gpt-4.1", usage: responses_usage(5000, 500, cached: 1000)))
  end

  define_case "faraday azure openai chat stream: deployment url" do
    faraday_sse("#{AZURE_OPENAI}/deployments/gpt4o-prod/chat/completions?api-version=2024-10-21",
                { stream: true, messages: [] },
                chat_stream_body(id: "chatcmpl_az4", model: "gpt-4o-2024-11-20", usage: chat_usage(2000, 300)))
  end

  define_case "faraday azure openai embeddings: deployment url" do
    faraday_json("#{AZURE_OPENAI}/deployments/emb/embeddings?api-version=2024-10-21", { input: "x" },
                 { object: "list", data: [], model: "text-embedding-3-large",
                   usage: { prompt_tokens: 5000, total_tokens: 5000 } })
  end

  define_case "faraday azure openai chat: services.ai.azure.com host" do
    faraday_json("https://contoso.services.ai.azure.com/openai/v1/chat/completions",
                 { model: "gpt-4.1-mini", messages: [] },
                 chat_completion(id: "chatcmpl_az6", model: "gpt-4.1-mini", usage: chat_usage(2000, 300)))
  end

  define_case "faraday azure openai chat: gpt-4.1 served on priority" do
    faraday_json("#{AZURE_OPENAI}/v1/chat/completions", { model: "gpt-4.1", messages: [], service_tier: "priority" },
                 chat_completion(id: "chatcmpl_az7", model: "gpt-4.1", usage: chat_usage(2000, 300),
                                 service_tier: "priority"))
  end

  define_case "faraday openai responses: o3 on flex with a web search call" do
    output = [{ type: "web_search_call", id: "ws_fx", status: "completed", action: { type: "search" } },
              output_message("fx")]
    faraday_json("#{OPENAI_API}/responses",
                 { model: "o3", input: "x", service_tier: "flex", tools: [{ type: "web_search" }] },
                 responses_object(id: "resp_fx", model: "o3", usage: responses_usage(3000, 500), output: output,
                                  service_tier: "flex"))
  end

  define_case "faraday openai responses: gpt-5.4 priority on the eu host with a file search call" do
    output = [{ type: "file_search_call", id: "fs_eu", status: "completed", queries: ["x"] }, output_message("eu2")]
    faraday_json("https://eu.api.openai.com/v1/responses", { model: "gpt-5.4", input: "x", service_tier: "priority" },
                 responses_object(id: "resp_eu2", model: "gpt-5.4", usage: responses_usage(3000, 500), output: output,
                                  service_tier: "priority"))
  end

  define_case "faraday openai chat: usage.cost on the openai host" do
    usage = chat_usage(1000, 200).merge(cost: 0.5)
    faraday_json("#{OPENAI_API}/chat/completions", { model: "gpt-4o", messages: [] },
                 chat_completion(id: "chatcmpl_uc", model: "gpt-4o", usage: usage))
  end

  define_case "faraday azure openai chat: usage.cost" do
    usage = chat_usage(1000, 200).merge(cost: 0.5)
    faraday_json("#{AZURE_OPENAI}/v1/chat/completions", { model: "gpt-4o", messages: [] },
                 chat_completion(id: "chatcmpl_azuc", model: "gpt-4o", usage: usage))
  end

  define_case "faraday openai completions: gpt-3.5-turbo-instruct" do
    faraday_json("#{OPENAI_API}/completions", { model: "gpt-3.5-turbo-instruct", prompt: "x" },
                 { id: "cmpl_1", object: "text_completion", model: "gpt-3.5-turbo-instruct",
                   choices: [{ text: "ok", index: 0 }],
                   usage: { prompt_tokens: 1000, completion_tokens: 100, total_tokens: 1100 } })
  end

  define_case "faraday openai images: dall-e-2 variation without usage records nothing" do
    faraday_json("#{OPENAI_API}/images/variations", { model: "dall-e-2" },
                 { created: 1, data: [{ url: "https://x/a.png" }] })
  end

  define_case "faraday openai speech: gpt-4o-mini-tts SSE usage at the text input and audio output rates" do
    faraday_sse("#{OPENAI_API}/audio/speech",
                { model: "gpt-4o-mini-tts", voice: "alloy", input: "hello world", stream_format: "sse" },
                speech_sse(1000, 50_000))
  end

  define_case "faraday openai speech: binary audio body" do
    WebMock.stub_request(:post, "#{OPENAI_API}/audio/speech")
           .to_return(status: 200, body: "ID3\x00\x01".b, headers: { "Content-Type" => "audio/mpeg" })
    faraday_post("#{OPENAI_API}/audio/speech", { model: "tts-1", voice: "alloy", input: "hello world" })
  end

  define_case "faraday azure openai transcription: deployment url with duration usage" do
    faraday_json("#{AZURE_OPENAI}/deployments/whisper/audio/transcriptions?api-version=2024-10-21",
                 { model: "whisper-1" }, { text: "hi", usage: { type: "duration", seconds: 30 } })
  end

  define_case "faraday openai transcription: gpt-4o-transcribe-diarize token usage" do
    faraday_json("#{OPENAI_API}/audio/transcriptions", { model: "gpt-4o-transcribe-diarize" },
                 { text: "hi", usage: { type: "tokens", input_tokens: 1200, output_tokens: 300, total_tokens: 1500,
                                        input_token_details: { audio_tokens: 1200, text_tokens: 0 } } })
  end

  define_case "faraday openai chat stream: 60 tool-call chunks of 28 KB before usage" do
    chunks = Array.new(60) { |i| large_tool_call_chunk("chatcmpl_fovf", i) }
    usage_chunk = { id: "chatcmpl_fovf", object: "chat.completion.chunk", model: "gpt-4o", choices: [],
                    usage: chat_usage(100, 10) }
    faraday_sse("#{OPENAI_API}/chat/completions", { model: "gpt-4o", stream: true, messages: [] },
                sse(*chunks, usage_chunk, done: true))
  end

  define_case "faraday openai chat: o3 with zero reasoning tokens" do
    faraday_json("#{OPENAI_API}/chat/completions", { model: "o3", messages: [] },
                 chat_completion(id: "chatcmpl_r5c17", model: "o3", usage: chat_usage(1000, 500)))
  end

  define_case "faraday openai responses: background response polled until completed" do
    faraday_json("#{OPENAI_API}/responses", { model: "o3-pro", input: "hi", background: true },
                 background_response("resp_bgF1", "queued"))
    stub_background_polls(OPENAI_API, "resp_bgF1")
    3.times { faraday_request(:get, "#{OPENAI_API}/responses/resp_bgF1") }
  end

  define_case "faraday azure openai responses: background response polled until completed" do
    faraday_json("#{AZURE_OPENAI}/v1/responses", { model: "o3-pro", input: "hi", background: true },
                 background_response("resp_bgAz", "queued"))
    stub_background_polls("#{AZURE_OPENAI}/v1", "resp_bgAz")
    3.times { faraday_request(:get, "#{AZURE_OPENAI}/v1/responses/resp_bgAz") }
  end

  define_case "faraday openai responses: background gpt-5.4 web search call polled" do
    tools = [{ type: "web_search" }]
    faraday_json("#{OPENAI_API}/responses", { model: "gpt-5.4", input: "hi", background: true, tools: tools },
                 background_response("resp_bgWS", "queued", model: "gpt-5.4", tools: tools))
    web_search = { type: "web_search_call", id: "ws_1", status: "completed", action: { type: "search", query: "q" } }
    done = background_response("resp_bgWS", "completed", usage: responses_usage(2000, 300), model: "gpt-5.4",
                               tools: tools).merge(output: [web_search, output_message("resp_bgWS")])
    stub_json(:get, "#{OPENAI_API}/responses/resp_bgWS", done)
    faraday_request(:get, "#{OPENAI_API}/responses/resp_bgWS")
  end

  define_case "faraday openai responses: completed response retrieved after create" do
    body = responses_object(id: "resp_nbg", model: "gpt-4o", usage: responses_usage(1000, 100))
    faraday_json("#{OPENAI_API}/responses", { model: "gpt-4o", input: "hi" }, body)
    stub_json(:get, "#{OPENAI_API}/responses/resp_nbg", body)
    faraday_request(:get, "#{OPENAI_API}/responses/resp_nbg")
  end

  define_case "faraday openai responses: input_items and delete record nothing" do
    stub_json(:get, "#{OPENAI_API}/responses/resp_x/input_items", { object: "list", data: [] })
    stub_json(:delete, "#{OPENAI_API}/responses/resp_x", { id: "resp_x", object: "response", deleted: true })
    faraday_request(:get, "#{OPENAI_API}/responses/resp_x/input_items")
    faraday_request(:delete, "#{OPENAI_API}/responses/resp_x")
  end

  define_case "faraday openai responses stream: background stream completed, then polled" do
    faraday_sse("#{OPENAI_API}/responses", { model: "o3-pro", input: "hi", background: true, stream: true },
                background_stream_body("resp_bgF4"))
    stub_json(:get, "#{OPENAI_API}/responses/resp_bgF4",
              background_response("resp_bgF4", "completed", usage: responses_usage(1000, 500)))
    faraday_request(:get, "#{OPENAI_API}/responses/resp_bgF4")
  end

  define_case "faraday openai responses: resumed background stream records nothing" do
    stub_sse(:get, "#{OPENAI_API}/responses/resp_rs?stream=true",
             responses_stream_body(id: "resp_rs", model: "o3-pro", usage: responses_usage(1000, 500)))
    faraday_request(:get, "#{OPENAI_API}/responses/resp_rs?stream=true")
  end

  define_case "faraday openai responses stream: background stream dropped before completion, then polled" do
    faraday_sse("#{OPENAI_API}/responses", { model: "o3-pro", input: "hi", background: true, stream: true },
                dropped_background_stream_body("resp_bgF5"))
    stub_json(:get, "#{OPENAI_API}/responses/resp_bgF5",
              background_response("resp_bgF5", "completed", usage: responses_usage(1000, 500)))
    2.times { faraday_request(:get, "#{OPENAI_API}/responses/resp_bgF5") }
  end

  define_case "faraday openai responses: background poll returning incomplete with usage" do
    body = background_response("resp_bgF6", "completed", usage: responses_usage(1000, 500))
    stub_json(:get, "#{OPENAI_API}/responses/resp_bgF6",
              body.merge(status: "incomplete", incomplete_details: { reason: "max_output_tokens" }))
    faraday_request(:get, "#{OPENAI_API}/responses/resp_bgF6")
  end

  define_case "faraday openai responses: background gpt-5.4 polled on the eu host" do
    stub_json(:get, "https://eu.api.openai.com/v1/responses/resp_bgEU",
              background_response("resp_bgEU", "completed", usage: responses_usage(10_000, 1000), model: "gpt-5.4"))
    faraday_request(:get, "https://eu.api.openai.com/v1/responses/resp_bgEU")
  end

  define_case "faraday openai transcription: gpt-transcribe on the eu host" do
    faraday_json("https://eu.api.openai.com/v1/audio/transcriptions", { model: "gpt-transcribe" },
                 { text: "hi", usage: { type: "duration", seconds: 125 } })
  end

  define_case "faraday openai transcription: whisper-1 on the eu host" do
    faraday_json("https://eu.api.openai.com/v1/audio/transcriptions", { model: "whisper-1" },
                 { text: "hi", usage: { type: "duration", seconds: 125 } })
  end

  define_case "faraday openai transcription: gpt-transcribe with flex requested" do
    faraday_json("#{OPENAI_API}/audio/transcriptions", { model: "gpt-transcribe", service_tier: "flex" },
                 { text: "hi", usage: { type: "duration", seconds: 60 } })
  end

  define_case "faraday openai transcription: gpt-4o-transcribe-diarize duration usage" do
    faraday_json("#{OPENAI_API}/audio/transcriptions",
                 { model: "gpt-4o-transcribe-diarize", response_format: "diarized_json" },
                 { text: "hi", segments: [], usage: { type: "duration", seconds: 60 } })
  end

  define_case "faraday openai transcription: whisper-1 json with 5s usage" do
    faraday_json("#{OPENAI_API}/audio/transcriptions", { model: "whisper-1" },
                 { text: "hi", usage: { type: "duration", seconds: 5 } })
  end

  define_case "faraday openai transcription: whisper-1 verbose_json with 8.47s duration and 9s usage" do
    faraday_json("#{OPENAI_API}/audio/transcriptions", { model: "whisper-1", response_format: "verbose_json" },
                 { task: "transcribe", language: "english", duration: 8.470000267028809, text: "hi", segments: [],
                   usage: { type: "duration", seconds: 9 } })
  end

  define_case "faraday azure openai transcription: verbose duration without usage" do
    faraday_json("#{AZURE_OPENAI}/deployments/whisper/audio/transcriptions?api-version=2024-10-21",
                 { model: "whisper-1", response_format: "verbose_json" },
                 { task: "transcribe", language: "english", duration: 30.2, text: "hi", segments: [] })
  end

  define_case "faraday azure openai transcription: deployment url with body model whisper" do
    faraday_json("#{AZURE_OPENAI}/deployments/whisper/audio/transcriptions?api-version=2024-10-21",
                 { model: "whisper" }, { text: "hi", usage: { type: "duration", seconds: 30 } })
  end

  define_case "faraday azure openai transcription: deployment url without a body model" do
    faraday_json("#{AZURE_OPENAI}/deployments/whisper/audio/transcriptions?api-version=2024-10-21",
                 { language: "en" }, { text: "hi", usage: { type: "duration", seconds: 30 } })
  end

  define_case "faraday azure openai transcription: v1 url with body model whisper" do
    faraday_json("#{AZURE_OPENAI}/v1/audio/transcriptions", { model: "whisper" },
                 { text: "hi", usage: { type: "duration", seconds: 30 } })
  end
end
