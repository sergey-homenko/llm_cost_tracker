# frozen_string_literal: true

module AccountingCases
  define_case "faraday openrouter chat: billed cost" do
    faraday_json("#{OPENROUTER_API}/chat/completions", { model: "openai/gpt-4o", messages: [] },
                 chat_completion(id: "gen-or1", model: "openai/gpt-4o",
                                 usage: openrouter_usage(3000, 500, cost: 0.0123),
                                 extra: { provider: "OpenAI" }))
  end

  define_case "faraday openrouter chat: billed cost for a llama model" do
    faraday_json("#{OPENROUTER_API}/chat/completions", { model: "meta-llama/llama-3.3-70b-instruct", messages: [] },
                 chat_completion(id: "gen-or2", model: "meta-llama/llama-3.3-70b-instruct",
                                 usage: openrouter_usage(3000, 500, cost: 0.00364)))
  end

  define_case "faraday openrouter chat: byok fee with upstream cost" do
    faraday_json("#{OPENROUTER_API}/chat/completions", { model: "anthropic/claude-sonnet-4.5", messages: [] },
                 chat_completion(id: "gen-or3", model: "anthropic/claude-sonnet-4.5",
                                 usage: openrouter_usage(3000, 500, cost: 0.000825, byok: true, upstream: 0.0165)))
  end

  define_case "faraday openrouter chat: byok fee without upstream cost" do
    faraday_json("#{OPENROUTER_API}/chat/completions", { model: "anthropic/claude-sonnet-4.5", messages: [] },
                 chat_completion(id: "gen-or4", model: "anthropic/claude-sonnet-4.5",
                                 usage: openrouter_usage(3000, 500, cost: 0.000825, byok: true, upstream: nil)))
  end

  define_case "faraday openrouter chat: no billed cost" do
    usage = chat_usage(3000, 500)
    faraday_json("#{OPENROUTER_API}/chat/completions", { model: "openai/gpt-4o", messages: [] },
                 chat_completion(id: "gen-or5", model: "openai/gpt-4o", usage: usage))
  end

  define_case "faraday openrouter chat: free model with zero cost" do
    faraday_json("#{OPENROUTER_API}/chat/completions", { model: "openai/gpt-oss-20b:free", messages: [] },
                 chat_completion(id: "gen-or6", model: "openai/gpt-oss-20b:free",
                                 usage: openrouter_usage(3000, 500, cost: 0)))
  end

  define_case "faraday openrouter chat: billed cost with cached tokens" do
    faraday_json("#{OPENROUTER_API}/chat/completions", { model: "openai/gpt-4o", messages: [] },
                 chat_completion(id: "gen-or7", model: "openai/gpt-4o",
                                 usage: openrouter_usage(10_000, 500, cost: 0.01875, cached: 5000)))
  end

  define_case "faraday openrouter chat: billed cost for an unlisted model" do
    faraday_json("#{OPENROUTER_API}/chat/completions", { model: "acme/unlisted-9b", messages: [] },
                 chat_completion(id: "gen-or8", model: "acme/unlisted-9b",
                                 usage: openrouter_usage(3000, 500, cost: 0.0042)))
  end

  define_case "faraday openrouter chat stream: billed cost in the final chunk" do
    faraday_sse("#{OPENROUTER_API}/chat/completions",
                { model: "meta-llama/llama-3.3-70b-instruct", stream: true, messages: [] },
                chat_stream_body(id: "gen-or9", model: "meta-llama/llama-3.3-70b-instruct",
                                 usage: openrouter_usage(3000, 500, cost: 0.00364)))
  end

  define_case "faraday openrouter responses: billed cost" do
    usage = responses_usage(4000, 600).merge(cost: 0.0156, is_byok: false)
    faraday_json("#{OPENROUTER_API}/responses", { model: "openai/gpt-4o", input: "x" },
                 responses_object(id: "gen-or10", model: "openai/gpt-4o", usage: usage))
  end

  define_case "faraday openrouter embeddings: billed cost" do
    faraday_json("#{OPENROUTER_API}/embeddings", { model: "openai/text-embedding-3-small", input: "x" },
                 { object: "list", data: [], model: "openai/text-embedding-3-small",
                   usage: { prompt_tokens: 1000, total_tokens: 1000, cost: 0.00002 } })
  end

  define_case "faraday openrouter chat: billed cost given as a string" do
    usage = openrouter_usage(3000, 500, cost: 0).merge(cost: "0.0123")
    faraday_json("#{OPENROUTER_API}/chat/completions", { model: "openai/gpt-4o", messages: [] },
                 chat_completion(id: "gen-or11", model: "openai/gpt-4o", usage: usage))
  end

  define_case "faraday deepseek chat: cache hit and miss fields" do
    usage = chat_usage(1000, 200, cached: 600, reasoning: 50)
            .merge(prompt_cache_hit_tokens: 600, prompt_cache_miss_tokens: 400)
    faraday_json("https://api.deepseek.com/chat/completions", { model: "deepseek-chat", messages: [] },
                 chat_completion(id: "ds1", model: "deepseek-chat", usage: usage))
  end

  define_case "faraday deepseek chat stream: usage in the last choice chunk" do
    usage = chat_usage(1000, 200, cached: 600).merge(prompt_cache_hit_tokens: 600, prompt_cache_miss_tokens: 400)
    faraday_sse("https://api.deepseek.com/chat/completions", { model: "deepseek-reasoner", stream: true, messages: [] },
                chat_stream_body(id: "ds2", model: "deepseek-reasoner", usage: usage, usage_in_last_choice: true))
  end

  define_case "faraday groq chat: on_demand tier" do
    faraday_json("#{GROQ_API}/chat/completions", { model: "openai/gpt-oss-120b", messages: [] },
                 chat_completion(id: "chatcmpl-gq1", model: "openai/gpt-oss-120b", usage: groq_usage(10_000, 1000),
                                 service_tier: "on_demand", extra: { x_groq: { id: "req_1" } }))
  end

  define_case "faraday groq chat: cached tokens" do
    faraday_json("#{GROQ_API}/chat/completions", { model: "openai/gpt-oss-120b", messages: [] },
                 chat_completion(id: "chatcmpl-gq2", model: "openai/gpt-oss-120b",
                                 usage: groq_usage(10_000, 1000, cached: 4000)))
  end

  define_case "faraday groq chat: flex tier" do
    faraday_json("#{GROQ_API}/chat/completions", { model: "openai/gpt-oss-120b", messages: [], service_tier: "flex" },
                 chat_completion(id: "chatcmpl-gq3", model: "openai/gpt-oss-120b", usage: groq_usage(10_000, 1000),
                                 service_tier: "flex"))
  end

  define_case "faraday groq chat stream: usage only in x_groq" do
    items = [
      chat_chunk(id: "chatcmpl-gq4", model: "openai/gpt-oss-20b",
                 choices: [{ index: 0, delta: { content: "hi" }, finish_reason: nil }]),
      chat_chunk(id: "chatcmpl-gq4", model: "openai/gpt-oss-20b",
                 choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
                 extra: { x_groq: { id: "req_4", usage: groq_usage(5000, 300) } })
    ]
    faraday_sse("#{GROQ_API}/chat/completions", { model: "openai/gpt-oss-20b", stream: true, messages: [] },
                sse(*items, done: true))
  end

  define_case "faraday groq chat stream: usage and x_groq usage" do
    items = [
      chat_chunk(id: "chatcmpl-gq5", model: "openai/gpt-oss-20b",
                 choices: [{ index: 0, delta: { content: "hi" }, finish_reason: nil }]),
      chat_chunk(id: "chatcmpl-gq5", model: "openai/gpt-oss-20b", choices: [], usage: groq_usage(5000, 300),
                 extra: { x_groq: { id: "req_5", usage: groq_usage(5000, 300) } })
    ]
    faraday_sse("#{GROQ_API}/chat/completions", { model: "openai/gpt-oss-20b", stream: true, messages: [] },
                sse(*items, done: true))
  end

  define_case "faraday groq chat: usage.cost" do
    usage = groq_usage(10_000, 1000).merge(cost: 0.5)
    faraday_json("#{GROQ_API}/chat/completions", { model: "openai/gpt-oss-120b", messages: [] },
                 chat_completion(id: "chatcmpl-gquc", model: "openai/gpt-oss-120b", usage: usage))
  end

  define_case "faraday openrouter chat: byok with zero fee and upstream cost" do
    faraday_json("#{OPENROUTER_API}/chat/completions", { model: "anthropic/claude-sonnet-4.5", messages: [] },
                 chat_completion(id: "gen-bz", model: "anthropic/claude-sonnet-4.5",
                                 usage: openrouter_usage(3000, 500, cost: 0, byok: true, upstream: 0.0165)))
  end

  define_case "faraday openrouter chat: online model with url citations and billed cost" do
    faraday_json("#{OPENROUTER_API}/chat/completions", { model: "openai/gpt-4o:online", messages: [] },
                 chat_completion(id: "gen-web", model: "openai/gpt-4o:online",
                                 usage: openrouter_usage(3000, 500, cost: 0.0323),
                                 annotations: [{ type: "url_citation",
                                                 url_citation: { url: "https://x", title: "x" } }]))
  end

  define_case "faraday openrouter chat: usage.cost given as an object" do
    usage = chat_usage(3000, 500).merge(cost: { total_cost: 0.02, request_cost: 0.005 })
    faraday_json("#{OPENROUTER_API}/chat/completions", { model: "perplexity/sonar", messages: [] },
                 chat_completion(id: "gen-pp", model: "perplexity/sonar", usage: usage))
  end

  define_case "faraday xai chat: grok-4.7 reasoning tokens with cached tokens", configure: XAI_AND_MISTRAL_HOSTS do
    faraday_json("#{XAI_API}/chat/completions", { model: "grok-4.7", messages: USER_MESSAGES },
                 chat_completion(id: "xai_c1", model: "grok-4.7",
                                 usage: xai_chat_usage(12_000, 500, reasoning: 2500, cached: 8000)))
  end

  define_case "faraday xai chat stream: grok-4.7 reasoning tokens in the usage chunk",
              configure: XAI_AND_MISTRAL_HOSTS do
    faraday_sse("#{XAI_API}/chat/completions",
                { model: "grok-4.7", stream: true, stream_options: { include_usage: true }, messages: [] },
                chat_stream_body(id: "xai_c2", model: "grok-4.7",
                                 usage: xai_chat_usage(12_000, 500, reasoning: 2500, cached: 8000)))
  end

  define_case "faraday xai responses stream: grok-4.7 reasoning tokens", configure: XAI_AND_MISTRAL_HOSTS do
    faraday_sse("#{XAI_API}/responses", { model: "grok-4.7", stream: true, input: "hi" },
                responses_stream_body(id: "resp_xai6", model: "grok-4.7",
                                      usage: xai_responses_usage(32, 9, reasoning: 110, cached: 8)))
  end

  define_case "faraday xai chat: grok-4.7 image prompt tokens", configure: XAI_AND_MISTRAL_HOSTS do
    faraday_json("#{XAI_API}/chat/completions", { model: "grok-4.7", messages: [] },
                 chat_completion(id: "xai_c11", model: "grok-4.7",
                                 usage: xai_chat_usage(1000, 100, reasoning: 0, image: 800)))
  end

  define_case "faraday xai chat: grok-4.7 priority on the us host", configure: XAI_AND_MISTRAL_HOSTS do
    faraday_json("#{XAI_US_API}/chat/completions", { model: "grok-4.7", service_tier: "priority", messages: [] },
                 chat_completion(id: "xai_c12", model: "grok-4.7", usage: xai_chat_usage(10_000, 10_000, reasoning: 0),
                                 service_tier: "priority"))
  end

  define_case "faraday xai chat: grok-4.7 priority on the us host with image, cached and reasoning tokens",
              configure: XAI_AND_MISTRAL_HOSTS do
    usage = xai_chat_usage(10_000, 1000, reasoning: 3000, cached: 2000, image: 4000)
    faraday_json("#{XAI_US_API}/chat/completions", { model: "grok-4.7", service_tier: "priority", messages: [] },
                 chat_completion(id: "xai_c13", model: "grok-4.7", usage: usage, service_tier: "priority"))
  end

  define_case "faraday xai chat: grok-4.7 long context with reasoning tokens", configure: XAI_AND_MISTRAL_HOSTS do
    faraday_json("#{XAI_API}/chat/completions", { model: "grok-4.7", messages: [] },
                 chat_completion(id: "xai_c14", model: "grok-4.7",
                                 usage: xai_chat_usage(250_000, 1000, reasoning: 4000)))
  end

  define_case "faraday mistral chat: medium-latest priority on the eu host", configure: XAI_AND_MISTRAL_HOSTS do
    usage = { prompt_tokens: 10_000, completion_tokens: 10_000, total_tokens: 20_000, service_tier: "priority" }
    faraday_json("https://api.eu.mistral.ai/v1/chat/completions", { model: "mistral-medium-latest", messages: [] },
                 chat_completion(id: "mis_c15", model: "mistral-medium-latest", usage: usage))
  end

  define_case "faraday xai chat: grok-4.7 on the unregistered global host" do
    faraday_json("#{XAI_API}/chat/completions", { model: "grok-4.7", messages: USER_MESSAGES },
                 chat_completion(id: "xai_c16", model: "grok-4.7",
                                 usage: xai_chat_usage(10_000, 1000, reasoning: 2000, cached: 4000)))
  end

  define_case "faraday mistral chat: medium-latest on the unregistered us host" do
    usage = { prompt_tokens: 10_000, completion_tokens: 1000, total_tokens: 11_000 }
    faraday_json("https://api.us.mistral.ai/v1/chat/completions",
                 { model: "mistral-medium-latest", messages: USER_MESSAGES },
                 chat_completion(id: "mis_c17", model: "mistral-medium-latest", usage: usage))
  end

  define_case "faraday mistral chat stream: medium-latest on the unregistered global host" do
    usage = { prompt_tokens: 2000, completion_tokens: 500, total_tokens: 2500 }
    faraday_sse("https://api.mistral.ai/v1/chat/completions",
                { model: "mistral-medium-latest", stream: true, messages: USER_MESSAGES },
                chat_stream_body(id: "mis_c18", model: "mistral-medium-latest", usage: usage))
  end

  define_case "faraday openrouter chat: gpt-5-search-api without billed cost" do
    faraday_json("#{OPENROUTER_API}/chat/completions", { model: "openai/gpt-5-search-api", messages: [] },
                 chat_completion(id: "gen-rv2", model: "openai/gpt-5-search-api", usage: chat_usage(1000, 500)))
  end

  define_case "faraday xai chat: grok-4.7 billed cost_in_usd_ticks" do
    usage = xai_chat_usage(12_000, 500, reasoning: 2500, cached: 8000).merge(cost_in_usd_ticks: 300_000_000)
    faraday_json("#{XAI_API}/chat/completions", { model: "grok-4.7", messages: USER_MESSAGES },
                 chat_completion(id: "xai_b1", model: "grok-4.7", usage: usage))
  end

  define_case "faraday xai chat stream: grok-4.7 billed cost_in_usd_ticks with the injected include_usage" do
    usage = xai_chat_usage(2000, 300, reasoning: 700, cached: 1000).merge(cost_in_usd_ticks: 85_000_000)
    WebMock.stub_request(:post, "#{XAI_API}/chat/completions")
           .with { |request| JSON.parse(request.body).dig("stream_options", "include_usage") }
           .to_return(status: 200, body: chat_stream_body(id: "xai_b2", model: "grok-4.7", usage: usage),
                      headers: { "Content-Type" => "text/event-stream" })
    faraday_post("#{XAI_API}/chat/completions", { model: "grok-4.7", stream: true, messages: USER_MESSAGES })
  end

  define_case "faraday perplexity chat: sonar-pro billed total_cost on the unregistered host" do
    cost = { input_tokens_cost: 0.0036, output_tokens_cost: 0.012, request_cost: 0.006, total_cost: 0.0216 }
    faraday_json("#{PERPLEXITY_API}/chat/completions", { model: "sonar-pro", messages: USER_MESSAGES },
                 chat_completion(id: "pplx_b1", model: "sonar-pro", usage: perplexity_usage(1200, 800, cost)))
  end

  define_case "faraday perplexity chat stream: sonar billed total_cost in the done chunk after zero-cost chunks" do
    pending = { input_tokens_cost: 0, output_tokens_cost: 0, total_cost: 0 }
    billed = { input_tokens_cost: 0.002, output_tokens_cost: 0.001, request_cost: 0.005, total_cost: 0.008 }
    chunks = [[400, nil, pending, {}], [1000, "stop", billed, { object: "chat.completion.done" }]]
    items = chunks.map do |completion, finish, cost, extra|
      chat_chunk(id: "pplx_b2", model: "sonar", usage: perplexity_usage(2000, completion, cost), extra: extra,
                 choices: [{ index: 0, delta: { content: "ok" }, finish_reason: finish }])
    end
    faraday_sse("#{PERPLEXITY_API}/chat/completions", { model: "sonar", stream: true, messages: USER_MESSAGES },
                sse(*items))
  end

  define_case "faraday xai images: grok-imagine-image-2.0 billed cost_in_usd_ticks" do
    faraday_json("#{XAI_API}/images/generations", { model: "grok-imagine-image-2.0", prompt: "a cat on a rocket" },
                 { data: [{ url: "https://imgen.x.ai/xai-imgen/xai-tmp-imgen-b8.jpeg", mime_type: "image/jpeg" }],
                   usage: { cost_in_usd_ticks: 400_000_000 } })
  end

  define_case "faraday perplexity sonar: sonar-pro billed total_cost on /v1/sonar" do
    cost = { input_tokens_cost: 0.0045, output_tokens_cost: 0.009, request_cost: 0.006, total_cost: 0.0195 }
    faraday_json("#{PERPLEXITY_API}/v1/sonar", { model: "sonar-pro", messages: USER_MESSAGES },
                 chat_completion(id: "pplx_b4", model: "sonar-pro", usage: perplexity_usage(1500, 600, cost)))
  end

  define_case "faraday perplexity agent: gpt-5.6-terra web search billed total_cost on /v1/agent" do
    usage = perplexity_agent_usage(500, 200, input_cost: 0.001, output_cost: 0.0024, tool_calls_cost: 0.0025,
                                             total_cost: 0.0059)
    search = { type: "search_results", queries: ["hi"],
               results: [{ id: 1, title: "x", url: "https://x", snippet: "x", source: "web" }] }
    faraday_json("#{PERPLEXITY_API}/v1/agent",
                 { model: "openai/gpt-5.6-terra", input: "hi", tools: [{ type: "web_search" }] },
                 responses_object(id: "resp_pplx_b5", model: "openai/gpt-5.6-terra", usage: usage,
                                  output: [search, output_message("pplx_b5")]))
  end

  define_case "faraday perplexity agent background: one row at the billed total_cost across polls" do
    run = { id: "resp_pplx_bg", object: "response", created_at: 1_758_000_000, model: "openai/gpt-5.6-terra",
            background: true, output: [] }
    usage = perplexity_agent_usage(500, 200, input_cost: 0.001, output_cost: 0.0024, tool_calls_cost: 0.0025,
                                             total_cost: 0.0059)
    done = run.merge(status: "completed", output: [output_message("pplx_bg")], usage: usage)
    faraday_json("#{PERPLEXITY_API}/v1/agent", { model: "openai/gpt-5.6-terra", input: "hi", background: true },
                 run.merge(status: "queued"))
    stub_json_sequence(:get, "#{PERPLEXITY_API}/v1/agent/resp_pplx_bg", run.merge(status: "in_progress"), done)
    stub_json(:get, "#{PERPLEXITY_API}/v1/responses/resp_pplx_bg", done)
    3.times { faraday_request(:get, "#{PERPLEXITY_API}/v1/agent/resp_pplx_bg") }
    faraday_request(:get, "#{PERPLEXITY_API}/v1/responses/resp_pplx_bg")
  end

  define_case "faraday perplexity agent stream: the fast preset recorded as the model that served it" do
    usage = perplexity_agent_usage(11_000, 1000, cached: 10_000, input_cost: 0.0001, cache_read_cost: 0.0001,
                                                 output_cost: 0.0005, tool_calls_cost: 0.0025, total_cost: 0.0032)
    created = { id: "resp_pplx_b6", object: "response", model: "fast", status: "in_progress", output: [] }
    done = created.merge(model: "openai/gpt-6-luna", status: "completed", output: [output_message("pplx_b6")],
                         usage: usage)
    faraday_sse("#{PERPLEXITY_API}/v1/agent", { preset: "fast", stream: true, input: "What is Ruby?" },
                sse(["response.created", { type: "response.created", sequence_number: 0, response: created }],
                    ["response.completed", { type: "response.completed", sequence_number: 1, response: done }]))
  end
end
