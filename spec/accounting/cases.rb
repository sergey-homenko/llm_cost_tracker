# frozen_string_literal: true

require "json"
require "stringio"

module AccountingCases
  Case = Data.define(:name, :instrument, :configure, :async, :skip_on_ruby_llm_1, :block)

  ALL = []

  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze
  OPENAI_API = "https://api.openai.com/v1"
  AZURE_OPENAI = "https://contoso-east.openai.azure.com/openai"
  OPENROUTER_API = "https://openrouter.ai/api/v1"
  GROQ_API = "https://api.groq.com/openai/v1"
  ANTHROPIC_MESSAGES = "https://api.anthropic.com/v1/messages"
  GEMINI_MODELS = "https://generativelanguage.googleapis.com/v1beta/models"
  GEMINI_INTERACTIONS = "https://generativelanguage.googleapis.com/v1beta/interactions"
  XAI_API = "https://api.x.ai/v1"
  XAI_US_API = "https://us.api.x.ai/v1"
  USER_MESSAGES = [{ role: "user", content: "hi" }].freeze
  XAI_AND_MISTRAL_HOSTS = lambda do |config|
    config.capture.openai_compatible_providers.merge!("api.x.ai" => "xai", "us.api.x.ai" => "xai",
                                                      "api.eu.mistral.ai" => "mistral")
  end
  FALLBACK_AFTER_OUTPUT_USAGE = {
    input_tokens: 5_200, output_tokens: 900,
    iterations: [{ type: "message", model: "claude-fable-5-1", input_tokens: 5_000, output_tokens: 1_200 },
                 { type: "fallback_message", model: "claude-opus-4-8", input_tokens: 5_200, output_tokens: 900 }]
  }.freeze

  def self.define_case(name, instrument: nil, configure: nil, async: false, skip_on_ruby_llm_1: nil, &block)
    raise ArgumentError, "duplicate accounting case #{name}" if ALL.any? { |kase| kase.name == name }

    ALL << Case.new(name:, instrument:, configure:, async:, skip_on_ruby_llm_1:, block:)
  end

  def stub_json(method, url, body, status: 200, headers: {})
    WebMock.stub_request(method, url)
           .to_return(status: status, body: JSON.generate(body), headers: JSON_HEADERS.merge(headers))
  end

  def stub_json_sequence(method, url, *bodies)
    WebMock.stub_request(method, url)
           .to_return(*bodies.map { |body| { status: 200, body: JSON.generate(body), headers: JSON_HEADERS } })
  end

  def stub_sse(method, url, body)
    WebMock.stub_request(method, url)
           .to_return(status: 200, body: body, headers: { "Content-Type" => "text/event-stream" })
  end

  def sse(*items, done: false, crlf: false)
    separator = crlf ? "\r\n" : "\n"
    body = items.map do |item|
      type, data = item.is_a?(Array) ? item : [nil, item]
      event = type ? "event: #{type}#{separator}" : ""
      "#{event}data: #{data.is_a?(String) ? data : JSON.generate(data)}#{separator}#{separator}"
    end.join
    done ? "#{body}data: [DONE]#{separator}#{separator}" : body
  end

  def faraday_connection(url)
    uri = URI(url)
    Faraday.new(url: "#{uri.scheme}://#{uri.host}") do |faraday|
      faraday.use :llm_cost_tracker
      faraday.adapter :net_http
    end
  end

  def faraday_post(url, payload, on_data: false)
    faraday_connection(url).post(URI(url).request_uri) do |request|
      request.headers["Content-Type"] = "application/json"
      request.body = JSON.generate(payload)
      request.options.on_data = proc {} if on_data
    end
  end

  def faraday_request(method, url)
    faraday_connection(url).run_request(method, URI(url).request_uri, nil, JSON_HEADERS)
  end

  def faraday_json(url, payload, response, status: 200, headers: {})
    stub_json(:post, url, response, status: status, headers: headers)
    faraday_post(url, payload)
  end

  def faraday_sse(url, payload, body, on_data: false)
    stub_sse(:post, url, body)
    faraday_post(url, payload, on_data: on_data)
  end

  def openai_client(base_url = nil)
    base_url ? OpenAI::Client.new(api_key: "sk-test", base_url: base_url) : OpenAI::Client.new(api_key: "sk-test")
  end

  def anthropic_client = Anthropic::Client.new(api_key: "sk-ant-test")

  def audio_io = StringIO.new("RIFF....WAVEfmt ").tap { |io| io.set_encoding(Encoding::BINARY) }

  def png_io = StringIO.new("\x89PNG\r\n\x1A\n".b)

  def chat_usage(prompt, completion, cached: 0, reasoning: 0, audio_in: 0, audio_out: 0)
    {
      prompt_tokens: prompt, completion_tokens: completion, total_tokens: prompt + completion,
      prompt_tokens_details: { cached_tokens: cached, audio_tokens: audio_in },
      completion_tokens_details: { reasoning_tokens: reasoning, audio_tokens: audio_out,
                                   accepted_prediction_tokens: 0, rejected_prediction_tokens: 0 }
    }
  end

  def chat_completion(id:, model:, usage:, service_tier: nil, annotations: nil, extra: {})
    message = { role: "assistant", content: "ok", refusal: nil }
    message[:annotations] = annotations if annotations
    {
      id: id, object: "chat.completion", created: 1_758_000_000, model: model,
      choices: [{ index: 0, message: message, logprobs: nil, finish_reason: "stop" }],
      usage: usage, service_tier: service_tier, system_fingerprint: "fp_test"
    }.compact.merge(extra)
  end

  def responses_usage(input, output, cached: 0, reasoning: 0)
    {
      input_tokens: input, input_tokens_details: { cached_tokens: cached },
      output_tokens: output, output_tokens_details: { reasoning_tokens: reasoning },
      total_tokens: input + output
    }
  end

  def output_message(id)
    { type: "message", id: "msg_#{id}", status: "completed", role: "assistant",
      content: [{ type: "output_text", text: "ok", annotations: [] }] }
  end

  def responses_object(id:, model:, usage:, output: nil, service_tier: nil)
    {
      id: id, object: "response", created_at: 1_758_000_000, status: "completed", model: model,
      output: output || [output_message(id)], usage: usage, service_tier: service_tier,
      parallel_tool_calls: true, tool_choice: "auto", tools: []
    }.compact
  end

  def chat_chunk(id:, model:, choices:, usage: nil, service_tier: nil, extra: {})
    { id: id, object: "chat.completion.chunk", created: 1_758_000_000, model: model,
      service_tier: service_tier, system_fingerprint: "fp_test", choices: choices, usage: usage }
      .compact.merge(extra)
  end

  def chat_stream_body(id:, model:, usage:, service_tier: nil, delta_annotations: nil, usage_in_last_choice: false)
    stream = { id: id, model: model, service_tier: service_tier }
    items = [{ role: "assistant", content: "" }, { content: "Hel" }, { content: "lo" }].map do |delta|
      chat_chunk(**stream, choices: [{ index: 0, delta: delta, finish_reason: nil }])
    end
    final_delta = delta_annotations ? { annotations: delta_annotations } : {}
    final_choices = [{ index: 0, delta: final_delta, finish_reason: "stop" }]
    if usage_in_last_choice
      items << chat_chunk(**stream, choices: final_choices, usage: usage)
    else
      items << chat_chunk(**stream, choices: final_choices)
      items << chat_chunk(**stream, choices: [], usage: usage) if usage
    end
    sse(*items, done: true)
  end

  def responses_stream_body(id:, model:, usage:, output: nil, service_tier: nil)
    output ||= [output_message(id)]
    base = { id: id, object: "response", created_at: 1_758_000_000, model: model, status: "in_progress",
             output: [], usage: nil, service_tier: service_tier }.compact
    events = [
      ["response.created", { type: "response.created", sequence_number: 0, response: base }],
      ["response.in_progress", { type: "response.in_progress", sequence_number: 1, response: base }]
    ]
    output.each_with_index do |item, index|
      events << ["response.output_item.done",
                 { type: "response.output_item.done", sequence_number: 2 + index, output_index: index, item: item }]
    end
    completed = base.merge(status: "completed", output: output, usage: usage)
    events << ["response.completed",
               { type: "response.completed", sequence_number: 9 + output.size, response: completed }]
    sse(*events)
  end

  def background_response(id, status, usage: nil, model: "o3-pro", tools: [])
    { id: id, object: "response", created_at: 1_758_000_000, model: model, status: status, background: true,
      output: status == "completed" ? [output_message(id)] : [], usage: usage, tools: tools, service_tier: "default" }
  end

  def stub_background_polls(base, id)
    stub_json_sequence(:get, "#{base}/responses/#{id}", background_response(id, "in_progress"),
                       background_response(id, "completed", usage: responses_usage(1000, 500)))
  end

  def background_stream_body(id)
    responses_stream_body(id: id, model: "o3-pro", usage: responses_usage(1000, 500))
      .gsub(/"status":"(in_progress|completed)"/, '"status":"\1","background":true')
  end

  def dropped_background_stream_body(id)
    response = { id: id, object: "response", created_at: 1, model: "o3-pro", status: "in_progress", background: true,
                 output: [], usage: nil }
    sse(["response.created", { type: "response.created", sequence_number: 0, response: response }],
        ["response.in_progress", { type: "response.in_progress", sequence_number: 1, response: response }])
  end

  def xai_chat_usage(prompt, completion, reasoning:, cached: 0, image: 0)
    { prompt_tokens: prompt, completion_tokens: completion, total_tokens: prompt + completion + reasoning,
      prompt_tokens_details: { text_tokens: prompt - image, audio_tokens: 0, image_tokens: image,
                               cached_tokens: cached },
      completion_tokens_details: { reasoning_tokens: reasoning, audio_tokens: 0, accepted_prediction_tokens: 0,
                                   rejected_prediction_tokens: 0 },
      num_sources_used: 0 }
  end

  def xai_responses_usage(input, output, reasoning:, cached: 0)
    { input_tokens: input, input_tokens_details: { cached_tokens: cached }, output_tokens: output,
      output_tokens_details: { reasoning_tokens: reasoning }, total_tokens: input + output + reasoning,
      num_sources_used: 0, num_server_side_tools_used: 0 }
  end

  def stub_openai_batch(host:, batch_id:, status:, endpoint:, lines:, model: nil)
    file_id = "file_out_#{batch_id}"
    stub_json(:get, "https://#{host}/v1/batches/#{batch_id}",
              { id: batch_id, object: "batch", endpoint: endpoint, status: status, model: model,
                input_file_id: "file_in_#{batch_id}", output_file_id: file_id, completion_window: "24h",
                created_at: 1_758_000_000,
                request_counts: { total: lines.size, completed: lines.size, failed: 0 } }.compact)
    WebMock.stub_request(:get, "https://#{host}/v1/files/#{file_id}/content").to_return(
      status: 200, body: "#{lines.map { |line| JSON.generate(line) }.join("\n")}\n",
      headers: { "Content-Type" => "application/octet-stream" }
    )
  end

  def forget_retrieved_openai_batches
    LlmCostTracker::Integrations::Openai::BatchCapture.instance_variable_set(:@dedup, nil)
  end

  def openai_batch_line(request_id, custom_id, body)
    { id: request_id, custom_id: custom_id,
      response: { status_code: 200, request_id: "req_#{request_id}", body: body }, error: nil }
  end

  def openrouter_usage(prompt, completion, cost:, byok: false, upstream: nil, cached: 0)
    { prompt_tokens: prompt, completion_tokens: completion, total_tokens: prompt + completion, cost: cost,
      is_byok: byok, prompt_tokens_details: { cached_tokens: cached, audio_tokens: 0 },
      cost_details: { upstream_inference_cost: upstream, upstream_inference_prompt_cost: 0,
                      upstream_inference_completions_cost: 0 },
      completion_tokens_details: { reasoning_tokens: 0, image_tokens: 0 } }
  end

  def groq_usage(prompt, completion, cached: 0)
    { queue_time: 0.01, prompt_tokens: prompt, prompt_time: 0.02, completion_tokens: completion, completion_time: 0.4,
      total_tokens: prompt + completion, total_time: 0.42, prompt_tokens_details: { cached_tokens: cached } }
  end

  def large_tool_call_chunk(id, index)
    tool_calls = Array.new(4) do |call|
      { "index" => call, "function" => { "arguments" => "#{index}-#{call}-#{'x' * 7000}" } }
    end
    { "id" => id, "object" => "chat.completion.chunk", "model" => "gpt-4o",
      "choices" => [{ "index" => 0, "delta" => { "tool_calls" => tool_calls } }] }
  end

  def anthropic_request(model = "claude-sonnet-4-5-20250929", **extra)
    { model: model, max_tokens: 1024, messages: USER_MESSAGES }.merge(extra)
  end

  def anthropic_usage(input, output, cache_read: 0, cache_5m: 0, cache_1h: 0, extra: {})
    { input_tokens: input, output_tokens: output, cache_read_input_tokens: cache_read,
      cache_creation_input_tokens: cache_5m + cache_1h,
      cache_creation: { ephemeral_5m_input_tokens: cache_5m, ephemeral_1h_input_tokens: cache_1h },
      service_tier: "standard" }.merge(extra)
  end

  def anthropic_message(id:, model:, usage:, content: nil, stop_reason: "end_turn")
    { id: id, type: "message", role: "assistant", model: model,
      content: content || [{ type: "text", text: "ok" }],
      stop_reason: stop_reason, stop_sequence: nil, usage: usage }
  end

  def anthropic_stream_body(id:, model:, start_usage:, delta_usage:, blocks: [%w[text Hello]],
                            delta: { stop_reason: "end_turn", stop_sequence: nil })
    message = { id: id, type: "message", role: "assistant", model: model, content: [],
                stop_reason: nil, stop_sequence: nil, usage: start_usage }
    events = [["message_start", { type: "message_start", message: message }], ["ping", { type: "ping" }]]
    blocks.each_with_index { |(kind, text), index| events.concat(anthropic_block_events(kind, text, index)) }
    events << ["message_delta", { type: "message_delta", delta: delta, usage: delta_usage }]
    events << ["message_stop", { type: "message_stop" }]
    sse(*events)
  end

  def anthropic_block_events(kind, text, index)
    block, deltas =
      case kind
      when "thinking"
        [{ type: "thinking", thinking: "", signature: "" },
         [{ type: "thinking_delta", thinking: text }, { type: "signature_delta", signature: "sig" }]]
      when "server_tool_use"
        [{ type: "server_tool_use", id: "srvtoolu_#{index}", name: "web_search", input: {} },
         [{ type: "input_json_delta", partial_json: JSON.generate(query: text) }]]
      else
        [{ type: "text", text: "" }, [{ type: "text_delta", text: text }]]
      end
    [["content_block_start", { type: "content_block_start", index: index, content_block: block }],
     *deltas.map { |delta| ["content_block_delta", { type: "content_block_delta", index: index, delta: delta }] },
     ["content_block_stop", { type: "content_block_stop", index: index }]]
  end

  def advisor_usage(advisor: "claude-opus-5", **extra)
    { input_tokens: 1_760, cache_read_input_tokens: 412, cache_creation_input_tokens: 0, output_tokens: 531,
      iterations: [
        { type: "message", input_tokens: 412, cache_read_input_tokens: 0, output_tokens: 89 },
        { type: "advisor_message", model: advisor, input_tokens: 823, cache_read_input_tokens: 0,
          cache_creation_input_tokens: 0, output_tokens: 1_612 },
        { type: "message", input_tokens: 1_348, cache_read_input_tokens: 412, output_tokens: 442 }
      ] }.merge(extra)
  end

  def anthropic_batch_result(custom_id, message)
    { custom_id: custom_id, result: { type: "succeeded", message: message } }
  end

  def stub_anthropic_batch(batch_id, lines)
    WebMock.stub_request(:get, %r{https://api\.anthropic\.com/v1/messages/batches/#{batch_id}/results}).to_return(
      status: 200, body: "#{lines.map { |line| JSON.generate(line) }.join("\n")}\n",
      headers: { "Content-Type" => "application/x-jsonl" }
    )
  end

  def gemini_usage(
    prompt:,
    candidates:,
    thoughts: nil,
    cached: nil,
    prompt_details: nil,
    cache_details: nil,
    candidate_details: nil,
    tool_use: nil,
    tool_use_details: nil,
    service_tier: nil
  )
    {
      promptTokenCount: prompt, candidatesTokenCount: candidates,
      totalTokenCount: prompt + candidates + thoughts.to_i + tool_use.to_i, cachedContentTokenCount: cached,
      promptTokensDetails: prompt_details || [{ modality: "TEXT", tokenCount: prompt }],
      cacheTokensDetails: cache_details,
      candidatesTokensDetails: candidate_details || [{ modality: "TEXT", tokenCount: candidates }],
      thoughtsTokenCount: thoughts, toolUsePromptTokenCount: tool_use, toolUsePromptTokensDetails: tool_use_details,
      serviceTier: service_tier
    }.compact
  end

  def gemini_response(model:, usage:, id: "gem_resp", grounding: nil, parts: nil)
    candidate = { content: { parts: parts || [{ text: "ok" }], role: "model" }, finishReason: "STOP", index: 0 }
    if grounding
      candidate[:groundingMetadata] = {
        webSearchQueries: grounding,
        groundingChunks: [{ web: { uri: "https://vertexaisearch.cloud.google.com/x", title: "example.com" } }],
        searchEntryPoint: { renderedContent: "<div></div>" }
      }
    end
    { candidates: [candidate], usageMetadata: usage, modelVersion: model, responseId: id }.compact
  end

  def modalities(**token_counts) = token_counts.map { |modality, count| { modality: modality.to_s, tokenCount: count } }

  def faraday_gemini(model, usage, request: gemini_request, headers: {}, **response)
    faraday_json(gemini_url(model), request, gemini_response(model: model, usage: usage, **response), headers: headers)
  end

  def gemini_cached_audio_usage(candidates)
    gemini_usage(prompt: 20_000, candidates: candidates, cached: 16_000,
                 prompt_details: modalities(TEXT: 1000, AUDIO: 19_000), cache_details: modalities(AUDIO: 16_000))
  end

  def gemini_request(**extra) = { contents: [{ role: "user", parts: [{ text: "hi" }] }] }.merge(extra)

  def interaction_usage(input:, output:, thought: 0)
    { input_tokens_by_modality: [{ modality: "text", tokens: input }], total_cached_tokens: 0,
      total_input_tokens: input, total_output_tokens: output, total_thought_tokens: thought,
      total_tokens: input + output + thought, total_tool_use_tokens: 0 }
  end

  def interaction(id, status, usage: nil, model: "gemini-3.1-pro-preview")
    { id: id, model: model, object: "interaction", status: status, service_tier: "standard",
      created: "2026-09-26T12:00:00Z", updated: "2026-09-26T12:00:00Z",
      steps: status == "completed" ? [{ type: "model_output", content: [{ type: "text", text: "ok" }] }] : [],
      usage: usage }.compact
  end

  def gemini_url(model, stream: false)
    stream ? "#{GEMINI_MODELS}/#{model}:streamGenerateContent?alt=sse" : "#{GEMINI_MODELS}/#{model}:generateContent"
  end
end
