# frozen_string_literal: true

module AccountingCases
  INTERNAL_COMPATIBLE_HOST = lambda do |config|
    config.capture.openai_compatible_providers = { "llm.internal.test" => "internal" }
  end
  URL_CITATIONS = [
    { type: "url_citation", url_citation: { url: "https://x", title: "x", start_index: 0, end_index: 1 } }
  ].freeze

  define_case "openai sdk chat: gpt-4o with cached tokens", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/chat/completions",
              chat_completion(id: "chatcmpl_sdk1", model: "gpt-4o", usage: chat_usage(50, 25, cached: 10)))
    openai_client.chat.completions.create(model: "gpt-4o", messages: USER_MESSAGES)
  end

  define_case "openai sdk chat: gpt-audio audio tokens", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/chat/completions",
              chat_completion(id: "chatcmpl_sdk2", model: "gpt-audio",
                              usage: chat_usage(1200, 900, audio_in: 1000, audio_out: 800)))
    openai_client.chat.completions.create(model: "gpt-audio", messages: USER_MESSAGES)
  end

  define_case "openai sdk chat: gpt-5.4 on priority", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/chat/completions",
              chat_completion(id: "chatcmpl_sdk3", model: "gpt-5.4", usage: chat_usage(10_000, 1000),
                              service_tier: "priority"))
    openai_client.chat.completions.create(model: "gpt-5.4", service_tier: :priority, messages: USER_MESSAGES)
  end

  define_case "openai sdk chat: gpt-5-search-api dated snapshot", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/chat/completions",
              chat_completion(id: "chatcmpl_sdk4", model: "gpt-5-search-api-2025-10-14", usage: chat_usage(1000, 500)))
    openai_client.chat.completions.create(model: "gpt-5-search-api", messages: USER_MESSAGES)
  end

  define_case "openai sdk chat: gpt-4o answer with a url citation", instrument: :openai do
    citation = { url: "https://x.test", title: "x", start_index: 0, end_index: 1 }
    stub_json(:post, "#{OPENAI_API}/chat/completions",
              chat_completion(id: "chatcmpl_sdk5", model: "gpt-4o", usage: chat_usage(500, 100),
                              annotations: [{ type: "url_citation", url_citation: citation }]))
    openai_client.chat.completions.create(model: "gpt-4o", messages: USER_MESSAGES)
  end

  define_case "openai sdk responses: gpt-4o with cached and reasoning tokens", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/responses",
              responses_object(id: "resp_sdk1", model: "gpt-4o",
                               usage: responses_usage(50, 25, cached: 10, reasoning: 5)))
    openai_client.responses.create(model: "gpt-4o", input: "hi")
  end

  define_case "openai sdk responses: gpt-4o on priority", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/responses",
              responses_object(id: "resp_sdk2", model: "gpt-4o", usage: responses_usage(100, 25),
                               service_tier: "priority"))
    openai_client.responses.create(model: "gpt-4o", input: "hi", service_tier: :priority)
  end

  define_case "openai sdk responses: web search, file search and code interpreter calls", instrument: :openai do
    output = [
      { type: "web_search_call", id: "ws_1", status: "completed", action: { type: "search", query: "q" } },
      { type: "file_search_call", id: "fs_1", status: "completed", queries: ["q"] },
      { type: "code_interpreter_call", id: "ci_1", status: "completed", container_id: "container-42",
        code: "print(1)", outputs: [] }
    ]
    stub_json(:post, "#{OPENAI_API}/responses",
              responses_object(id: "resp_sdk3", model: "gpt-4o", usage: responses_usage(50, 25), output: output))
    openai_client.responses.create(model: "gpt-4o", input: "hi")
  end

  define_case "openai sdk responses: image generation call", instrument: :openai do
    output = [{ type: "image_generation_call", id: "ig_1", status: "completed", result: "iVBORw0KGgo=" }]
    stub_json(:post, "#{OPENAI_API}/responses",
              responses_object(id: "resp_sdk4", model: "gpt-5.5-2026-04-23", usage: responses_usage(2000, 200),
                               output: output))
    openai_client.responses.create(model: "gpt-5.5", input: "Draw a cat", tools: [{ type: :image_generation }])
  end

  define_case "openai sdk responses: o3 on flex", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/responses",
              responses_object(id: "resp_sdk5", model: "o3",
                               usage: responses_usage(20_000, 3000, cached: 5000, reasoning: 2000),
                               service_tier: "flex"))
    openai_client.responses.create(model: "o3", input: "hi", service_tier: :flex)
  end

  define_case "openai sdk responses: gpt-5.5-pro long context", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/responses",
              responses_object(id: "resp_sdk6", model: "gpt-5.5-pro", usage: responses_usage(300_000, 8000)))
    openai_client.responses.create(model: "gpt-5.5-pro", input: "hi")
  end

  define_case "openai sdk responses: gpt-6-astra on ultrafast, long context on the us host", instrument: :openai do
    stub_json(:post, "https://us.api.openai.com/v1/responses",
              responses_object(id: "resp_sdk7", model: "gpt-6-astra",
                               usage: responses_usage(300_000, 2000, cached: 100_000), service_tier: "ultrafast"))
    openai_client("https://us.api.openai.com/v1").responses.create(model: "gpt-6-astra", input: "hi",
                                                                   service_tier: :ultrafast)
  end

  define_case "openai sdk responses: queued background response records nothing", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/responses",
              { id: "resp_bg", object: "response", model: "o3-pro", status: "queued", background: true,
                created_at: 1, output: [], usage: nil })
    openai_client.responses.create(model: "o3-pro", input: "hi", background: true)
  end

  define_case "openai sdk embeddings: text-embedding-3-large", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/embeddings",
              { object: "list", data: [], model: "text-embedding-3-large",
                usage: { prompt_tokens: 30_000, total_tokens: 30_000 } })
    openai_client.embeddings.create(model: "text-embedding-3-large", input: "hi")
  end

  define_case "openai sdk images: gpt-image-1 generation", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/images/generations",
              { created: 1, data: [], usage: { input_tokens: 25, output_tokens: 4160, total_tokens: 4185,
                                               input_tokens_details: { image_tokens: 15, text_tokens: 10 } } })
    openai_client.images.generate(prompt: "a cat", model: "gpt-image-1")
  end

  define_case "openai sdk images: gpt-image-2.5-sunburst generation", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/images/generations",
              { created: 1, data: [{ b64_json: "iVBORw0KGgo=" }],
                usage: { input_tokens: 50, input_tokens_details: { text_tokens: 50, image_tokens: 0 },
                         output_tokens: 1056, total_tokens: 1106 } })
    openai_client.images.generate(model: "gpt-image-2.5-sunburst", prompt: "a cat")
  end

  define_case "openai sdk images: gpt-image-1 edit with cached input", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/images/edits",
              { created: 1, data: [{ b64_json: "iVBORw0KGgo=" }],
                usage: { input_tokens: 1000, output_tokens: 1056, total_tokens: 2056,
                         input_tokens_details: { text_tokens: 40, image_tokens: 960, cached_tokens: 500 },
                         output_tokens_details: { image_tokens: 1000, text_tokens: 56 } } })
    openai_client.images.edit(image: png_io, prompt: "blue", model: "gpt-image-1")
  end

  define_case "openai sdk images: gpt-image-1 on the eu host", instrument: :openai do
    stub_json(:post, "https://eu.api.openai.com/v1/images/generations",
              { created: 1, data: [], usage: { input_tokens: 25, output_tokens: 4160, total_tokens: 4185 } })
    openai_client("https://eu.api.openai.com/v1").images.generate(prompt: "a cat", model: "gpt-image-1")
  end

  define_case "openai sdk transcription: gpt-4o-transcribe token usage", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/audio/transcriptions",
              { text: "hello", usage: { type: "tokens", input_tokens: 12, output_tokens: 3, total_tokens: 15,
                                        input_token_details: { audio_tokens: 8, text_tokens: 4 } } })
    openai_client.audio.transcriptions.create(file: audio_io, model: "gpt-4o-transcribe")
  end

  define_case "openai sdk transcription: whisper-1 duration usage", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/audio/transcriptions",
              { text: "hello", usage: { type: "duration", seconds: 125.5 } })
    openai_client.audio.transcriptions.create(file: audio_io, model: "whisper-1")
  end

  define_case "openai sdk transcription: whisper-1 text response format", instrument: :openai do
    WebMock.stub_request(:post, "#{OPENAI_API}/audio/transcriptions")
           .to_return(status: 200, body: "hello world\n", headers: { "Content-Type" => "text/plain" })
    openai_client.audio.transcriptions.create(file: audio_io, model: "whisper-1", response_format: :text)
  end

  define_case "openai sdk transcription: gpt-4o-transcribe srt format without usage", instrument: :openai do
    WebMock.stub_request(:post, "#{OPENAI_API}/audio/transcriptions")
           .to_return(status: 200, body: "1\n00:00:00,000 --> 00:00:01,000\nhi\n",
                      headers: { "Content-Type" => "text/plain" })
    openai_client.audio.transcriptions.create(file: audio_io, model: "gpt-4o-transcribe", response_format: :srt)
  end

  define_case "openai sdk translation: whisper-1", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/audio/translations", { text: "hello" })
    openai_client.audio.translations.create(file: audio_io, model: "whisper-1")
  end

  define_case "openai sdk speech: tts-1 characters", instrument: :openai do
    WebMock.stub_request(:post, "#{OPENAI_API}/audio/speech")
           .to_return(status: 200, body: "mp3", headers: { "Content-Type" => "audio/mpeg" })
    openai_client.audio.speech.create(model: "tts-1", voice: "alloy", input: "hello world")
  end

  define_case "openai sdk speech: gpt-4o-mini-tts", instrument: :openai do
    WebMock.stub_request(:post, "#{OPENAI_API}/audio/speech")
           .to_return(status: 200, body: "mp3", headers: { "Content-Type" => "audio/mpeg" })
    openai_client.audio.speech.create(model: "gpt-4o-mini-tts", voice: "alloy", input: "hello world")
  end

  define_case "openai sdk moderation: omni-moderation-latest", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/moderations", { id: "modr_abc", model: "omni-moderation-latest", results: [] })
    openai_client.moderations.create(input: "hello")
  end

  define_case "openai sdk chat stream helper: gpt-4o with cached tokens", instrument: :openai do
    stub_sse(:post, "#{OPENAI_API}/chat/completions",
             chat_stream_body(id: "chatcmpl_ss1", model: "gpt-4o", usage: chat_usage(1000, 200, cached: 300)))
    openai_client.chat.completions.stream(model: "gpt-4o", messages: USER_MESSAGES).each { nil }
  end

  define_case "openai sdk chat stream_raw: gpt-4o", instrument: :openai do
    stub_sse(:post, "#{OPENAI_API}/chat/completions",
             chat_stream_body(id: "chatcmpl_ss2", model: "gpt-4o", usage: chat_usage(1000, 200)))
    openai_client.chat.completions.stream_raw(model: "gpt-4o", messages: USER_MESSAGES).each { nil }
  end

  define_case "openai sdk chat stream helper: without include_usage", instrument: :openai do
    stub_sse(:post, "#{OPENAI_API}/chat/completions", chat_stream_body(id: "chatcmpl_ss3", model: "gpt-4o", usage: nil))
    openai_client.chat.completions.stream(model: "gpt-4o", messages: USER_MESSAGES).each { nil }
  end

  define_case "openai sdk chat stream helper: 500 chunks with 20 logprobs each", instrument: :openai do
    base = { id: "chatcmpl_lp", object: "chat.completion.chunk", created: 1, model: "gpt-4.1-mini" }
    chunks = Array.new(500) do |i|
      top = Array.new(20) { |r| { token: " word#{i}#{r}", logprob: -1.0 - r, bytes: " word#{i}#{r}".bytes } }
      entry = { token: " word#{i}", logprob: -0.5, bytes: " word#{i}".bytes, top_logprobs: top }
      base.merge(choices: [{ index: 0, delta: { content: " word#{i}" }, logprobs: { content: [entry] },
                             finish_reason: nil }])
    end
    stop = base.merge(choices: [{ index: 0, delta: {}, finish_reason: "stop" }])
    stub_sse(:post, "#{OPENAI_API}/chat/completions",
             sse(*chunks, stop, base.merge(choices: [], usage: chat_usage(50, 500)), done: true))
    openai_client.chat.completions.stream(model: "gpt-4.1-mini", messages: USER_MESSAGES, logprobs: true,
                                          top_logprobs: 20, stream_options: { include_usage: true }).each { nil }
  end

  define_case "openai sdk chat stream_raw: 500 chunks with 20 logprobs each", instrument: :openai do
    base = { id: "chatcmpl_lpr", object: "chat.completion.chunk", created: 1, model: "gpt-4.1-mini" }
    chunks = Array.new(500) do |i|
      top = Array.new(20) { |r| { token: " word#{i}#{r}", logprob: -1.0 - r, bytes: " word#{i}#{r}".bytes } }
      entry = { token: " word#{i}", logprob: -0.5, bytes: " word#{i}".bytes, top_logprobs: top }
      base.merge(choices: [{ index: 0, delta: { content: " word#{i}" }, logprobs: { content: [entry] },
                             finish_reason: nil }])
    end
    stub_sse(:post, "#{OPENAI_API}/chat/completions",
             sse(*chunks, base.merge(choices: [], usage: chat_usage(50, 500)), done: true))
    openai_client.chat.completions.stream_raw(model: "gpt-4.1-mini", messages: USER_MESSAGES, logprobs: true,
                                              top_logprobs: 20, stream_options: { include_usage: true }).each { nil }
  end

  define_case "openai sdk chat stream_raw: priority requested but default served", instrument: :openai do
    stub_sse(:post, "#{OPENAI_API}/chat/completions",
             chat_stream_body(id: "chatcmpl_ss4", model: "gpt-5.5", service_tier: "default",
                              usage: chat_usage(10_000, 2000)))
    openai_client.chat.completions.stream_raw(model: "gpt-5.5", service_tier: :priority,
                                              messages: USER_MESSAGES).each { nil }
  end

  define_case "openai sdk chat stream_raw: priority requested and served", instrument: :openai do
    stub_sse(:post, "#{OPENAI_API}/chat/completions",
             chat_stream_body(id: "chatcmpl_ss5", model: "gpt-5.5", service_tier: "priority",
                              usage: chat_usage(10_000, 2000)))
    openai_client.chat.completions.stream_raw(model: "gpt-5.5", service_tier: :priority,
                                              messages: USER_MESSAGES).each { nil }
  end

  define_case "openai sdk chat stream_raw: priority requested with no tier in chunks", instrument: :openai do
    stub_sse(:post, "#{OPENAI_API}/chat/completions",
             chat_stream_body(id: "chatcmpl_ss6", model: "gpt-4o", usage: chat_usage(1000, 200)))
    openai_client.chat.completions.stream_raw(model: "gpt-4o", service_tier: :priority,
                                              messages: USER_MESSAGES).each { nil }
  end

  define_case "openai sdk chat stream_raw: flex requested on the eu host with no tier in chunks", instrument: :openai do
    stub_sse(:post, "https://eu.api.openai.com/v1/chat/completions",
             chat_stream_body(id: "chatcmpl_ss7", model: "gpt-5.4", usage: chat_usage(10_000, 1000)))
    client = openai_client("https://eu.api.openai.com/v1")
    client.chat.completions.stream_raw(model: "gpt-5.4", service_tier: :flex, messages: USER_MESSAGES).each { nil }
  end

  define_case "openai sdk chat stream_raw: gpt-5-search-api", instrument: :openai do
    stub_sse(:post, "#{OPENAI_API}/chat/completions",
             chat_stream_body(id: "chatcmpl_ss8", model: "gpt-5-search-api-2025-10-14", usage: chat_usage(1000, 500)))
    openai_client.chat.completions.stream_raw(model: "gpt-5-search-api", messages: USER_MESSAGES).each { nil }
  end

  define_case "openai sdk chat stream helper: gpt-5-search-api", instrument: :openai do
    stub_sse(:post, "#{OPENAI_API}/chat/completions",
             chat_stream_body(id: "chatcmpl_ss9", model: "gpt-5-search-api-2025-10-14", usage: chat_usage(1000, 500)))
    openai_client.chat.completions.stream(model: "gpt-5-search-api", messages: USER_MESSAGES).each { nil }
  end

  define_case "openai sdk chat stream_raw: 20000 chunks", instrument: :openai do
    chunk = { id: "chatcmpl_long", object: "chat.completion.chunk", model: "gpt-4o",
              choices: [{ index: 0, delta: { content: " token" } }] }
    stub_sse(:post, "#{OPENAI_API}/chat/completions",
             sse(*Array.new(20_000, chunk), chunk.merge(choices: [], usage: chat_usage(10, 20_000)), done: true))
    openai_client.chat.completions.stream_raw(model: "gpt-4o", messages: USER_MESSAGES).each { nil }
  end

  define_case "openai sdk responses stream helper: gpt-4o", instrument: :openai do
    stub_sse(:post, "#{OPENAI_API}/responses",
             responses_stream_body(id: "resp_ss1", model: "gpt-4o", usage: responses_usage(20, 7)))
    openai_client.responses.stream(model: "gpt-4o", input: "hi").each { nil }
  end

  define_case "openai sdk responses stream_raw: web search and code interpreter calls", instrument: :openai do
    output = [
      { type: "web_search_call", id: "ws_r1", status: "completed", action: { type: "search", query: "x" } },
      { type: "code_interpreter_call", id: "ci_r1", status: "completed", container_id: "cntr_9", code: "1",
        outputs: [] },
      output_message("ss2")
    ]
    stub_sse(:post, "#{OPENAI_API}/responses",
             responses_stream_body(id: "resp_ss2", model: "gpt-4.1", usage: responses_usage(3000, 300), output: output))
    openai_client.responses.stream_raw(model: "gpt-4.1", input: "hi", tools: [{ type: :web_search }]).each { nil }
  end

  define_case "openai sdk responses stream_raw: image generation call", instrument: :openai do
    output = [{ type: "image_generation_call", id: "ig_r1", status: "completed", result: "iVBORw0KGgo=" }]
    stub_sse(:post, "#{OPENAI_API}/responses",
             responses_stream_body(id: "resp_ss3", model: "gpt-5.5", usage: responses_usage(2000, 200), output: output))
    openai_client.responses.stream_raw(model: "gpt-5.5", input: "draw", tools: [{ type: :image_generation }])
                 .each { nil }
  end

  define_case "openai sdk responses stream_raw: completed response with logprobs", instrument: :openai do
    logprobs = Array.new(500) do |i|
      { token: " w#{i}", logprob: -0.5, bytes: [32],
        top_logprobs: Array.new(20) { |r| { token: " w#{i}#{r}", logprob: -1.0, bytes: [32] } } }
    end
    text = { type: "output_text", text: "x", annotations: [], logprobs: logprobs }
    response = { id: "resp_lp", object: "response", created_at: 1, model: "gpt-4.1-mini", status: "completed",
                 output: [{ type: "message", id: "msg_lp", role: "assistant", status: "completed", content: [text] }],
                 usage: responses_usage(50, 500) }
    stub_sse(:post, "#{OPENAI_API}/responses",
             sse(["response.completed", { type: "response.completed", sequence_number: 1, response: response }]))
    openai_client.responses.stream_raw(model: "gpt-4.1-mini", input: "hi", top_logprobs: 20,
                                       include: ["message.output_text.logprobs"]).each { nil }
  end

  define_case "openai sdk responses stream_raw: flex requested but default served", instrument: :openai do
    stub_sse(:post, "#{OPENAI_API}/responses",
             responses_stream_body(id: "resp_ss4", model: "o3", usage: responses_usage(20_000, 4000),
                                   service_tier: "default"))
    openai_client.responses.stream_raw(model: "o3", input: "hi", service_tier: :flex).each { nil }
  end

  define_case "openai sdk responses stream_raw: gpt-5.4-mini on the us host", instrument: :openai do
    stub_sse(:post, "https://us.api.openai.com/v1/responses",
             responses_stream_body(id: "resp_ss5", model: "gpt-5.4-mini", usage: responses_usage(10_000, 500),
                                   service_tier: "default"))
    openai_client("https://us.api.openai.com/v1/").responses.stream_raw(model: "gpt-5.4-mini", input: "hi").each { nil }
  end

  define_case "openai sdk responses stream_raw: gpt-5.5 priority on the eu host", instrument: :openai do
    stub_sse(:post, "https://eu.api.openai.com/v1/responses",
             responses_stream_body(id: "resp_ss6", model: "gpt-5.5", usage: responses_usage(10_000, 500),
                                   service_tier: "priority"))
    client = openai_client("https://eu.api.openai.com/v1/")
    client.responses.stream_raw(model: "gpt-5.5", input: "hi", service_tier: :priority).each { nil }
  end

  define_case "openai sdk responses retrieve_streaming: response without id", instrument: :openai do
    completed = { type: "response.completed", sequence_number: 1,
                  response: { model: "gpt-4o", usage: responses_usage(20, 7) } }
    stub_sse(:get, "#{OPENAI_API}/responses/resp_retrieve?stream=true", sse(["response.completed", completed]))
    openai_client.responses.retrieve_streaming("resp_retrieve").each { nil }
  end

  define_case "openai sdk images generate_stream_raw: gpt-image-1", instrument: :openai do
    data = { type: "image_generation.completed", b64_json: "", background: "opaque", created_at: 1,
             output_format: "png", quality: "high", size: "1024x1024",
             usage: { input_tokens: 10, output_tokens: 1500, total_tokens: 1510,
                      input_tokens_details: { image_tokens: 0, text_tokens: 10 } } }
    stub_sse(:post, "#{OPENAI_API}/images/generations", sse(["image_generation.completed", data]))
    openai_client.images.generate_stream_raw(prompt: "a cat", model: "gpt-image-1", partial_images: 1).each { nil }
  end

  define_case "openai sdk transcription create_streaming: gpt-4o-transcribe", instrument: :openai do
    data = { type: "transcript.text.done", text: "hello",
             usage: { type: "tokens", input_tokens: 400, output_tokens: 30, total_tokens: 430,
                      input_token_details: { audio_tokens: 380, text_tokens: 20 } } }
    stub_sse(:post, "#{OPENAI_API}/audio/transcriptions", sse(["transcript.text.done", data]))
    openai_client.audio.transcriptions.create_streaming(file: audio_io, model: "gpt-4o-transcribe").each { nil }
  end

  define_case "openai sdk azure openai responses: v1 url with cached tokens", instrument: :openai do
    stub_json(:post, "#{AZURE_OPENAI}/v1/responses",
              responses_object(id: "resp_saz1", model: "gpt-4o", usage: responses_usage(5000, 500, cached: 1000)))
    openai_client("#{AZURE_OPENAI}/v1/").responses.create(model: "gpt-4o", input: "hi")
  end

  define_case "openai sdk azure openai responses stream_raw: priority requested but default served",
              instrument: :openai do
    stub_sse(:post, "#{AZURE_OPENAI}/v1/responses",
             responses_stream_body(id: "resp_saz2", model: "gpt-4.1", usage: responses_usage(150_000, 2000),
                                   service_tier: "default"))
    openai_client("#{AZURE_OPENAI}/v1/").responses.stream_raw(model: "gpt-4.1", input: "hi",
                                                              service_tier: :priority).each { nil }
  end

  define_case "openai sdk azure openai embeddings: text-embedding-3-large", instrument: :openai do
    stub_json(:post, "#{AZURE_OPENAI}/v1/embeddings",
              { object: "list", data: [], model: "text-embedding-3-large",
                usage: { prompt_tokens: 5000, total_tokens: 5000 } })
    openai_client("#{AZURE_OPENAI}/v1/").embeddings.create(model: "text-embedding-3-large", input: "hi")
  end

  define_case "openai sdk groq chat: listed model", instrument: :openai do
    stub_json(:post, "#{GROQ_API}/chat/completions",
              chat_completion(id: "chatcmpl-sgq1", model: "openai/gpt-oss-120b", usage: groq_usage(10_000, 1000)))
    openai_client(GROQ_API).chat.completions.create(model: "openai/gpt-oss-120b", messages: USER_MESSAGES)
  end

  define_case "openai sdk groq chat stream_raw: listed model", instrument: :openai do
    stub_sse(:post, "#{GROQ_API}/chat/completions",
             chat_stream_body(id: "chatcmpl-sgq2", model: "openai/gpt-oss-20b", usage: groq_usage(5000, 300)))
    openai_client(GROQ_API).chat.completions.stream_raw(model: "openai/gpt-oss-20b", messages: USER_MESSAGES,
                                                        stream_options: { include_usage: true }).each { nil }
  end

  define_case "openai sdk xai chat: grok-4.7 on the unregistered us host", instrument: :openai do
    stub_json(:post, "#{XAI_US_API}/chat/completions",
              chat_completion(id: "xai_s1", model: "grok-4.7",
                              usage: xai_chat_usage(10_000, 1000, reasoning: 1000, cached: 2000)))
    openai_client(XAI_US_API).chat.completions.create(model: "grok-4.7", messages: USER_MESSAGES)
  end

  define_case "openai sdk openrouter chat: billed cost", instrument: :openai do
    stub_json(:post, "#{OPENROUTER_API}/chat/completions",
              chat_completion(id: "gen-sor1", model: "openai/gpt-4o", usage: openrouter_usage(3000, 500, cost: 0.0123)))
    openai_client(OPENROUTER_API).chat.completions.create(model: "openai/gpt-4o", messages: USER_MESSAGES)
  end

  define_case "openai sdk openrouter chat: byok fee with upstream cost", instrument: :openai do
    stub_json(:post, "#{OPENROUTER_API}/chat/completions",
              chat_completion(id: "gen-sor2", model: "anthropic/claude-sonnet-4.5",
                              usage: openrouter_usage(3000, 500, cost: 0.000825, byok: true, upstream: 0.0165)))
    openai_client(OPENROUTER_API).chat.completions.create(model: "anthropic/claude-sonnet-4.5", messages: USER_MESSAGES)
  end

  define_case "openai sdk openrouter chat stream_raw: billed cost", instrument: :openai do
    stub_sse(:post, "#{OPENROUTER_API}/chat/completions",
             chat_stream_body(id: "gen-sor3", model: "meta-llama/llama-3.3-70b-instruct",
                              usage: openrouter_usage(3000, 500, cost: 0.00364)))
    completions = openai_client(OPENROUTER_API).chat.completions
    completions.stream_raw(model: "meta-llama/llama-3.3-70b-instruct", messages: USER_MESSAGES,
                           stream_options: { include_usage: true }).each { nil }
  end

  define_case "openai sdk openrouter responses: billed cost", instrument: :openai do
    stub_json(:post, "#{OPENROUTER_API}/responses",
              responses_object(id: "gen-sor4", model: "openai/gpt-4o",
                               usage: responses_usage(4000, 600).merge(cost: 0.0156, is_byok: false)))
    openai_client(OPENROUTER_API).responses.create(model: "openai/gpt-4o", input: "hi")
  end

  define_case "openai sdk deepseek chat: cache hit and miss fields", instrument: :openai do
    usage = chat_usage(1000, 200, cached: 600).merge(prompt_cache_hit_tokens: 600, prompt_cache_miss_tokens: 400)
    stub_json(:post, "https://api.deepseek.com/chat/completions",
              chat_completion(id: "sds1", model: "deepseek-chat", usage: usage))
    openai_client("https://api.deepseek.com").chat.completions.create(model: "deepseek-chat", messages: USER_MESSAGES)
  end

  define_case "openai sdk chat: configured openai-compatible host",
              instrument: :openai, configure: INTERNAL_COMPATIBLE_HOST do
    stub_json(:post, "https://llm.internal.test/v1/chat/completions",
              chat_completion(id: "sint1", model: "gpt-4o", usage: chat_usage(1000, 100)))
    openai_client("https://llm.internal.test/v1").chat.completions.create(model: "gpt-4o", messages: USER_MESSAGES)
  end

  define_case "openai sdk chat: gpt-5.4 on the eu host with cached tokens", instrument: :openai do
    stub_json(:post, "https://eu.api.openai.com/v1/chat/completions",
              chat_completion(id: "chatcmpl_seu", model: "gpt-5.4", usage: chat_usage(10_000, 1000, cached: 2000)))
    openai_client("https://eu.api.openai.com/v1").chat.completions.create(model: "gpt-5.4", messages: USER_MESSAGES)
  end

  define_case "openai sdk responses: gpt-4o on the us host", instrument: :openai do
    stub_json(:post, "https://us.api.openai.com/v1/responses",
              responses_object(id: "resp_sus", model: "gpt-4o", usage: responses_usage(10, 5)))
    openai_client("https://us.api.openai.com/v1/").responses.create(model: "gpt-4o", input: "hi")
  end

  define_case "openai sdk chat: chat-latest", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/chat/completions",
              chat_completion(id: "chatcmpl_scl", model: "chat-latest", usage: chat_usage(3000, 700)))
    openai_client.chat.completions.create(model: "chat-latest", messages: USER_MESSAGES)
  end

  define_case "openai sdk transcription: json response without usage", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/audio/transcriptions", { text: "hello" })
    openai_client.audio.transcriptions.create(file: audio_io, model: "gpt-4o-transcribe")
  end

  define_case "openai sdk transcription: whisper-1 verbose_json with duration usage", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/audio/transcriptions",
              { task: "transcribe", language: "english", duration: 95.2, text: "hi", segments: [],
                usage: { type: "duration", seconds: 96 } })
    openai_client.audio.transcriptions.create(file: audio_io, model: "whisper-1", response_format: :verbose_json)
  end

  define_case "openai sdk images: gpt-image-1-mini generation", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/images/generations",
              { created: 1, data: [], usage: { input_tokens: 30, output_tokens: 272, total_tokens: 302,
                                               input_tokens_details: { text_tokens: 30, image_tokens: 0 } } })
    openai_client.images.generate(prompt: "a cat", model: "gpt-image-1-mini")
  end

  define_case "openai sdk openrouter embeddings: billed cost", instrument: :openai do
    stub_json(:post, "#{OPENROUTER_API}/embeddings",
              { object: "list", data: [], model: "openai/text-embedding-3-small",
                usage: { prompt_tokens: 1000, total_tokens: 1000, cost: 0.00002 } })
    openai_client(OPENROUTER_API).embeddings.create(model: "openai/text-embedding-3-small", input: "hi")
  end

  define_case "openai sdk openrouter chat stream helper: billed cost", instrument: :openai do
    stub_sse(:post, "#{OPENROUTER_API}/chat/completions",
             chat_stream_body(id: "gen-sh", model: "openai/gpt-4o", usage: openrouter_usage(3000, 500, cost: 0.0123)))
    openai_client(OPENROUTER_API).chat.completions.stream(model: "openai/gpt-4o", messages: USER_MESSAGES,
                                                          stream_options: { include_usage: true }).each { nil }
  end

  define_case "openai sdk responses stream helper: image generation call", instrument: :openai do
    output = [{ type: "image_generation_call", id: "ig_h1", status: "completed", result: "iVBORw0KGgo=" }]
    stub_sse(:post, "#{OPENAI_API}/responses",
             responses_stream_body(id: "resp_h1", model: "gpt-5.5", usage: responses_usage(2000, 200), output: output))
    openai_client.responses.stream(model: "gpt-5.5", input: "draw", tools: [{ type: :image_generation }]).each { nil }
  end

  define_case "openai sdk responses stream helper: web search call", instrument: :openai do
    output = [{ type: "web_search_call", id: "ws_h2", status: "completed", action: { type: "search", query: "x" } },
              output_message("h2")]
    stub_sse(:post, "#{OPENAI_API}/responses",
             responses_stream_body(id: "resp_h2", model: "gpt-4.1", usage: responses_usage(3000, 300), output: output))
    openai_client.responses.stream(model: "gpt-4.1", input: "x", tools: [{ type: :web_search }]).each { nil }
  end

  define_case "openai sdk chat stream helper: url citation in a delta", instrument: :openai do
    citation = { url: "https://x", title: "x", start_index: 0, end_index: 1 }
    stub_sse(:post, "#{OPENAI_API}/chat/completions",
             chat_stream_body(id: "chatcmpl_hc", model: "gpt-4o", usage: chat_usage(1000, 500),
                              delta_annotations: [{ type: "url_citation", url_citation: citation }]))
    openai_client.chat.completions.stream(model: "gpt-4o", messages: USER_MESSAGES).each { nil }
  end

  define_case "openai sdk azure openai chat stream helper: gpt-4o", instrument: :openai do
    stub_sse(:post, "#{AZURE_OPENAI}/v1/chat/completions",
             chat_stream_body(id: "chatcmpl_azh", model: "gpt-4o", usage: chat_usage(2000, 300)))
    openai_client("#{AZURE_OPENAI}/v1/").chat.completions.stream(model: "gpt-4o", messages: USER_MESSAGES,
                                                                 stream_options: { include_usage: true }).each { nil }
  end

  define_case "openai sdk images edit_stream_raw: gpt-image-1", instrument: :openai do
    data = { type: "image_edit.completed", b64_json: "", background: "opaque", created_at: 1, output_format: "png",
             quality: "high", size: "1024x1024",
             usage: { input_tokens: 400, output_tokens: 1500, total_tokens: 1900,
                      input_tokens_details: { image_tokens: 380, text_tokens: 20 } } }
    stub_sse(:post, "#{OPENAI_API}/images/edits", sse(["image_edit.completed", data]))
    openai_client.images.edit_stream_raw(image: png_io, prompt: "blue", model: "gpt-image-1", partial_images: 1)
                 .each { nil }
  end

  define_case "openai sdk chat stream_raw: 60 tool-call chunks of 28 KB before usage", instrument: :openai do
    chunks = Array.new(60) { |i| large_tool_call_chunk("chatcmpl_sovf", i) }
    usage_chunk = { id: "chatcmpl_sovf", object: "chat.completion.chunk", model: "gpt-4o", choices: [],
                    usage: chat_usage(100, 10) }
    stub_sse(:post, "#{OPENAI_API}/chat/completions", sse(*chunks, usage_chunk, done: true))
    openai_client.chat.completions.stream_raw(model: "gpt-4o", messages: USER_MESSAGES).each { nil }
  end

  define_case "openai sdk openrouter embeddings: no billed cost", instrument: :openai do
    stub_json(:post, "#{OPENROUTER_API}/embeddings",
              { object: "list", data: [], model: "openai/text-embedding-3-small",
                usage: { prompt_tokens: 100_000, total_tokens: 100_000 } })
    openai_client(OPENROUTER_API).embeddings.create(model: "openai/text-embedding-3-small", input: "hi")
  end

  define_case "openai sdk openrouter chat: gpt-5-search-api without billed cost", instrument: :openai do
    stub_json(:post, "#{OPENROUTER_API}/chat/completions",
              chat_completion(id: "gen-nc1", model: "openai/gpt-5-search-api", usage: chat_usage(1000, 500)))
    openai_client(OPENROUTER_API).chat.completions.create(model: "openai/gpt-5-search-api", messages: USER_MESSAGES)
  end

  define_case "openai sdk openrouter chat: dashed claude id without billed cost", instrument: :openai do
    stub_json(:post, "#{OPENROUTER_API}/chat/completions",
              chat_completion(id: "gen-nc2", model: "anthropic/claude-sonnet-4-5", usage: chat_usage(3000, 500)))
    openai_client(OPENROUTER_API).chat.completions.create(model: "anthropic/claude-sonnet-4-5", messages: USER_MESSAGES)
  end

  define_case "openai sdk openrouter chat: gpt-4o with cached tokens without billed cost", instrument: :openai do
    stub_json(:post, "#{OPENROUTER_API}/chat/completions",
              chat_completion(id: "gen-nc3", model: "openai/gpt-4o", usage: chat_usage(3000, 500, cached: 1000)))
    openai_client(OPENROUTER_API).chat.completions.create(model: "openai/gpt-4o", messages: USER_MESSAGES)
  end

  define_case "openai sdk openrouter chat: dated gpt-4o without billed cost", instrument: :openai do
    stub_json(:post, "#{OPENROUTER_API}/chat/completions",
              chat_completion(id: "gen-nc4", model: "openai/gpt-4o-2024-08-06", usage: chat_usage(3000, 500)))
    openai_client(OPENROUTER_API).chat.completions.create(model: "openai/gpt-4o-2024-08-06", messages: USER_MESSAGES)
  end

  define_case "openai sdk openrouter images: gpt-image-1 without billed cost", instrument: :openai do
    stub_json(:post, "#{OPENROUTER_API}/images/generations",
              { created: 1, data: [], usage: { input_tokens: 25, output_tokens: 4160, total_tokens: 4185 } })
    openai_client(OPENROUTER_API).images.generate(prompt: "a cat", model: "openai/gpt-image-1")
  end

  define_case "openai sdk groq chat: model missing from the groq price list", instrument: :openai do
    stub_json(:post, "#{GROQ_API}/chat/completions",
              chat_completion(id: "chatcmpl-gql", model: "llama-3.3-70b-versatile", usage: groq_usage(10_000, 1000)))
    openai_client(GROQ_API).chat.completions.create(model: "llama-3.3-70b-versatile", messages: USER_MESSAGES)
  end

  define_case "openai sdk chat: gpt-audio cached audio prompt tokens", instrument: :openai do
    usage = { prompt_tokens: 2000, completion_tokens: 300, total_tokens: 2300,
              prompt_tokens_details: { cached_tokens: 1200, audio_tokens: 1500, text_tokens: 500, image_tokens: 0 },
              completion_tokens_details: { reasoning_tokens: 0, audio_tokens: 200, text_tokens: 100 } }
    stub_json(:post, "#{OPENAI_API}/chat/completions",
              chat_completion(id: "chatcmpl_aud", model: "gpt-audio", usage: usage))
    openai_client.chat.completions.create(model: "gpt-audio", messages: USER_MESSAGES)
  end

  define_case "openai sdk xai chat: grok-4.7 reasoning tokens with cached tokens",
              instrument: :openai, configure: XAI_AND_MISTRAL_HOSTS do
    stub_json(:post, "#{XAI_API}/chat/completions",
              chat_completion(id: "xai_c3", model: "grok-4.7",
                              usage: xai_chat_usage(12_000, 500, reasoning: 2500, cached: 8000)))
    openai_client(XAI_API).chat.completions.create(model: "grok-4.7", messages: USER_MESSAGES)
  end

  define_case "openai sdk xai chat stream_raw: grok-4.7 reasoning tokens",
              instrument: :openai, configure: XAI_AND_MISTRAL_HOSTS do
    stub_sse(:post, "#{XAI_API}/chat/completions",
             chat_stream_body(id: "xai_c4", model: "grok-4.7",
                              usage: xai_chat_usage(12_000, 500, reasoning: 2500, cached: 8000)))
    openai_client(XAI_API).chat.completions.stream_raw(model: "grok-4.7", messages: USER_MESSAGES,
                                                       stream_options: { include_usage: true }).each { nil }
  end

  define_case "openai sdk xai responses: grok-4.7 reasoning tokens",
              instrument: :openai, configure: XAI_AND_MISTRAL_HOSTS do
    stub_json(:post, "#{XAI_API}/responses",
              responses_object(id: "resp_xai5", model: "grok-4.7",
                               usage: xai_responses_usage(32, 9, reasoning: 110, cached: 8)))
    openai_client(XAI_API).responses.create(model: "grok-4.7", input: "hi")
  end

  define_case "openai sdk xai responses stream_raw: grok-4.7 reasoning tokens",
              instrument: :openai, configure: XAI_AND_MISTRAL_HOSTS do
    stub_sse(:post, "#{XAI_API}/responses",
             responses_stream_body(id: "resp_xai7", model: "grok-4.7",
                                   usage: xai_responses_usage(32, 9, reasoning: 110, cached: 8)))
    openai_client(XAI_API).responses.stream_raw(model: "grok-4.7", input: "hi").each { nil }
  end

  define_case "openai sdk openrouter chat: grok-4.7 billed cost with reasoning tokens", instrument: :openai do
    usage = { prompt_tokens: 12_000, completion_tokens: 3000, total_tokens: 15_000, cost: 0.03,
              prompt_tokens_details: { cached_tokens: 8000 }, completion_tokens_details: { reasoning_tokens: 2500 } }
    stub_json(:post, "#{OPENROUTER_API}/chat/completions",
              chat_completion(id: "gen-xai16", model: "x-ai/grok-4.7", usage: usage))
    openai_client(OPENROUTER_API).chat.completions.create(model: "x-ai/grok-4.7", messages: USER_MESSAGES)
  end

  define_case "openai sdk responses: background response retrieved until completed", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/responses", background_response("resp_bgS1", "queued"))
    stub_background_polls(OPENAI_API, "resp_bgS1")
    client = openai_client
    client.responses.create(model: "o3-pro", input: "hi", background: true)
    3.times { client.responses.retrieve("resp_bgS1") }
  end

  define_case "openai sdk responses stream_raw: background stream dropped before completion, then retrieved",
              instrument: :openai do
    stub_sse(:post, "#{OPENAI_API}/responses", dropped_background_stream_body("resp_bgS3"))
    stub_background_polls(OPENAI_API, "resp_bgS3")
    client = openai_client
    client.responses.stream_raw(model: "o3-pro", input: "hi", background: true).each { nil }
    2.times { client.responses.retrieve("resp_bgS3") }
  end

  define_case "openai sdk chat and responses retrieve: tracking disabled records nothing",
              instrument: :openai, configure: ->(config) { config.enabled = false } do
    stub_json(:post, "#{OPENAI_API}/chat/completions",
              chat_completion(id: "chatcmpl_dis", model: "gpt-4o", usage: chat_usage(100, 10)))
    stub_json(:get, "#{OPENAI_API}/responses/resp_dis",
              background_response("resp_dis", "completed", usage: responses_usage(1000, 500)))
    client = openai_client
    client.chat.completions.create(model: "gpt-4o", messages: USER_MESSAGES)
    client.responses.retrieve("resp_dis")
  end

  define_case "openai sdk responses retrieve: background gpt-5.4 flex on the eu host", instrument: :openai do
    body = background_response("resp_bgEF", "completed", usage: responses_usage(10_000, 1000), model: "gpt-5.4")
    stub_json(:get, "https://eu.api.openai.com/v1/responses/resp_bgEF", body.merge(service_tier: "flex"))
    openai_client("https://eu.api.openai.com/v1").responses.retrieve("resp_bgEF")
  end

  define_case "openai sdk transcription: gpt-transcribe on the us host", instrument: :openai do
    stub_json(:post, "https://us.api.openai.com/v1/audio/transcriptions",
              { text: "hi", usage: { type: "duration", seconds: 125 } })
    openai_client("https://us.api.openai.com/v1").audio.transcriptions.create(file: audio_io, model: "gpt-transcribe")
  end

  define_case "openai sdk openrouter chat: gpt-5-search-api with billed cost", instrument: :openai do
    stub_json(:post, "#{OPENROUTER_API}/chat/completions",
              chat_completion(id: "gen-rv1", model: "openai/gpt-5-search-api",
                              usage: openrouter_usage(1000, 500, cost: 0.01625)))
    openai_client(OPENROUTER_API).chat.completions.create(model: "openai/gpt-5-search-api", messages: USER_MESSAGES)
  end

  define_case "openai sdk openrouter chat: gpt-4o-search-preview without billed cost", instrument: :openai do
    stub_json(:post, "#{OPENROUTER_API}/chat/completions",
              chat_completion(id: "gen-rv3", model: "openai/gpt-4o-search-preview", usage: chat_usage(1000, 500)))
    openai_client(OPENROUTER_API).chat.completions.create(model: "openai/gpt-4o-search-preview",
                                                          messages: USER_MESSAGES)
  end

  define_case "openai sdk openrouter chat: gpt-4o online with a url citation without billed cost",
              instrument: :openai do
    stub_json(:post, "#{OPENROUTER_API}/chat/completions",
              chat_completion(id: "gen-rv4", model: "openai/gpt-4o", usage: chat_usage(1000, 500),
                              annotations: URL_CITATIONS))
    openai_client(OPENROUTER_API).chat.completions.create(model: "openai/gpt-4o:online", messages: USER_MESSAGES)
  end

  define_case "openai sdk chat stream helper: gpt-4o without annotations", instrument: :openai do
    stub_sse(:post, "#{OPENAI_API}/chat/completions",
             chat_stream_body(id: "chatcmpl_rv5", model: "gpt-4o", usage: chat_usage(1000, 500)))
    openai_client.chat.completions.stream(model: "gpt-4o", messages: USER_MESSAGES).each { nil }
  end

  define_case "openai sdk chat stream_raw: url citation in a delta", instrument: :openai do
    stub_sse(:post, "#{OPENAI_API}/chat/completions",
             chat_stream_body(id: "chatcmpl_rv6", model: "gpt-4o", usage: chat_usage(1000, 500),
                              delta_annotations: URL_CITATIONS))
    openai_client.chat.completions.stream_raw(model: "gpt-4o", messages: USER_MESSAGES).each { nil }
  end

  define_case "openai sdk chat stream helper: gpt-4o-search-preview dated snapshot with a url citation in a delta",
              instrument: :openai do
    stub_sse(:post, "#{OPENAI_API}/chat/completions",
             chat_stream_body(id: "chatcmpl_rv7", model: "gpt-4o-search-preview-2025-03-11",
                              usage: chat_usage(1000, 500), delta_annotations: URL_CITATIONS))
    openai_client.chat.completions.stream(model: "gpt-4o-search-preview", messages: USER_MESSAGES).each { nil }
  end

  define_case "openai sdk chat stream helper: gpt-5-search-api dated snapshot with a url citation in a delta",
              instrument: :openai do
    stub_sse(:post, "#{OPENAI_API}/chat/completions",
             chat_stream_body(id: "chatcmpl_rv8", model: "gpt-5-search-api-2025-10-14",
                              usage: chat_usage(1000, 500), delta_annotations: URL_CITATIONS))
    openai_client.chat.completions.stream(model: "gpt-5-search-api", messages: USER_MESSAGES).each { nil }
  end

  define_case "openai sdk transcription: whisper-1 json with 9s usage", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/audio/transcriptions", { text: "hi", usage: { type: "duration", seconds: 9 } })
    openai_client.audio.transcriptions.create(file: audio_io, model: "whisper-1")
  end

  define_case "openai sdk transcription: whisper-1 verbose_json with 8.47s duration and 9s usage",
              instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/audio/transcriptions",
              { task: "transcribe", language: "english", duration: 8.470000267028809, text: "hi", segments: [],
                usage: { type: "duration", seconds: 9 } })
    openai_client.audio.transcriptions.create(file: audio_io, model: "whisper-1", response_format: :verbose_json)
  end

  define_case "openai sdk translation: whisper-1 duration usage", instrument: :openai do
    stub_json(:post, "#{OPENAI_API}/audio/translations", { text: "hi", usage: { type: "duration", seconds: 30 } })
    openai_client.audio.translations.create(file: audio_io, model: "whisper-1")
  end

  define_case "openai sdk xai responses: grok-4.7 web search billed in cost_in_usd_ticks", instrument: :openai do
    usage = xai_responses_usage(5000, 400, reasoning: 600)
            .merge(num_server_side_tools_used: 1, cost_in_usd_ticks: 210_000_000)
    stub_json(:post, "#{XAI_API}/responses", responses_object(id: "resp_xai_b3", model: "grok-4.7", usage: usage))
    openai_client(XAI_API).responses.create(model: "grok-4.7", input: "hi", tools: [{ type: "web_search" }])
  end

  define_case "openai sdk xai images: grok-imagine-image billed in cost_in_usd_ticks", instrument: :openai do
    stub_json(:post, "#{XAI_API}/images/generations",
              { data: [{ url: "https://imgen.x.ai/xai-imgen/xai-tmp-imgen-b4.jpeg", mime_type: "image/jpeg" }],
                usage: { cost_in_usd_ticks: 200_000_000 } })
    openai_client(XAI_API).images.generate(prompt: "a cat", model: "grok-imagine-image")
  end
end
