# frozen_string_literal: true

module AccountingCases
  define_case "openai batch chat: completed with two results and one error", instrument: :openai do
    lines = [
      openai_batch_line("batch_req_1", "c1", chat_completion(id: "chatcmpl_b1", model: "gpt-4o-2024-08-06",
                                                             usage: chat_usage(1000, 200, cached: 500))),
      openai_batch_line("batch_req_2", "c2", chat_completion(id: "chatcmpl_b2", model: "gpt-4o-2024-08-06",
                                                             usage: chat_usage(2000, 100))),
      { id: "batch_req_3", custom_id: "c3", response: nil, error: { code: "server_error", message: "x" } }
    ]
    stub_openai_batch(host: "api.openai.com", batch_id: "batch_c1", status: "completed",
                      endpoint: "/v1/chat/completions", lines: lines)
    openai_client.batches.retrieve("batch_c1")
  end

  define_case "openai batch chat: expired with a completed result", instrument: :openai do
    body = chat_completion(id: "chatcmpl_e1", model: "gpt-4o", usage: chat_usage(1000, 200))
    stub_openai_batch(host: "api.openai.com", batch_id: "batch_e1", status: "expired",
                      endpoint: "/v1/chat/completions", lines: [openai_batch_line("batch_req_e1", "c1", body)])
    openai_client.batches.retrieve("batch_e1")
  end

  define_case "openai batch chat: cancelled with a completed result", instrument: :openai do
    body = chat_completion(id: "chatcmpl_x1", model: "o3", usage: chat_usage(5000, 2000, reasoning: 1500))
    stub_openai_batch(host: "api.openai.com", batch_id: "batch_x1", status: "cancelled",
                      endpoint: "/v1/chat/completions", lines: [openai_batch_line("batch_req_x1", "c1", body)])
    openai_client.batches.retrieve("batch_x1")
  end

  define_case "openai batch chat: still cancelling records nothing", instrument: :openai do
    body = chat_completion(id: "chatcmpl_y1", model: "gpt-4o", usage: chat_usage(1000, 200))
    stub_openai_batch(host: "api.openai.com", batch_id: "batch_y1", status: "cancelling",
                      endpoint: "/v1/chat/completions", lines: [openai_batch_line("batch_req_y1", "c1", body)])
    openai_client.batches.retrieve("batch_y1")
  end

  define_case "openai batch embeddings: results without body ids", instrument: :openai do
    body = { object: "list", data: [], model: "text-embedding-3-small",
             usage: { prompt_tokens: 50_000, total_tokens: 50_000 } }
    lines = [openai_batch_line("batch_req_emb1", "e1", body), openai_batch_line("batch_req_emb2", "e2", body)]
    stub_openai_batch(host: "api.openai.com", batch_id: "batch_emb", status: "completed", endpoint: "/v1/embeddings",
                      lines: lines, model: "text-embedding-3-small")
    openai_client.batches.retrieve("batch_emb")
  end

  define_case "openai batch embeddings: retrieved by two processes", instrument: :openai do
    body = { object: "list", data: [], model: "text-embedding-3-small",
             usage: { prompt_tokens: 50_000, total_tokens: 50_000 } }
    stub_openai_batch(host: "api.openai.com", batch_id: "batch_emb2", status: "completed", endpoint: "/v1/embeddings",
                      lines: [openai_batch_line("batch_req_emb3", "e1", body)])
    openai_client.batches.retrieve("batch_emb2")
    forget_retrieved_openai_batches
    openai_client.batches.retrieve("batch_emb2")
  end

  define_case "openai batch chat: retrieved by two processes", instrument: :openai do
    body = chat_completion(id: "chatcmpl_d1", model: "gpt-4o", usage: chat_usage(1000, 200))
    stub_openai_batch(host: "api.openai.com", batch_id: "batch_d1", status: "completed",
                      endpoint: "/v1/chat/completions", lines: [openai_batch_line("batch_req_d1", "c1", body)])
    openai_client.batches.retrieve("batch_d1")
    forget_retrieved_openai_batches
    openai_client.batches.retrieve("batch_d1")
  end

  define_case "openai batch images: gpt-image-1 generations", instrument: :openai do
    body = { created: 1, data: [], usage: { input_tokens: 50, output_tokens: 1056, total_tokens: 1106,
                                            input_tokens_details: { text_tokens: 50, image_tokens: 0 } } }
    stub_openai_batch(host: "api.openai.com", batch_id: "batch_img", status: "completed",
                      endpoint: "/v1/images/generations", lines: [openai_batch_line("batch_req_img1", "i1", body)],
                      model: "gpt-image-1")
    openai_client.batches.retrieve("batch_img")
  end

  define_case "openai batch responses: gpt-5.5 dated snapshot", instrument: :openai do
    body = responses_object(id: "resp_b1", model: "gpt-5.5-2026-04-23",
                            usage: responses_usage(8000, 1500, cached: 2000, reasoning: 800))
    stub_openai_batch(host: "api.openai.com", batch_id: "batch_resp", status: "completed", endpoint: "/v1/responses",
                      lines: [openai_batch_line("batch_req_r1", "r1", body)])
    openai_client.batches.retrieve("batch_resp")
  end

  define_case "openai batch chat: gpt-5.4 on the eu host", instrument: :openai do
    body = chat_completion(id: "chatcmpl_dr", model: "gpt-5.4-2026-03-05",
                           usage: chat_usage(200_000, 20_000, cached: 50_000))
    stub_openai_batch(host: "eu.api.openai.com", batch_id: "batch_eu", status: "completed",
                      endpoint: "/v1/chat/completions", lines: [openai_batch_line("batch_req_eu1", "c1", body)])
    openai_client("https://eu.api.openai.com/v1").batches.retrieve("batch_eu")
  end

  define_case "openai batch chat: gpt-5.4 on the au host", instrument: :openai do
    body = chat_completion(id: "chatcmpl_au", model: "gpt-5.4-2026-03-05",
                           usage: chat_usage(200_000, 20_000, cached: 50_000))
    stub_openai_batch(host: "au.api.openai.com", batch_id: "batch_au", status: "completed",
                      endpoint: "/v1/chat/completions", lines: [openai_batch_line("batch_req_au1", "c1", body)])
    openai_client("https://au.api.openai.com/v1").batches.retrieve("batch_au")
  end

  define_case "openai batch chat: gpt-4o on the us host", instrument: :openai do
    body = chat_completion(id: "chatcmpl_usb", model: "gpt-4o", usage: chat_usage(20_000, 2000))
    stub_openai_batch(host: "us.api.openai.com", batch_id: "batch_us", status: "completed",
                      endpoint: "/v1/chat/completions", lines: [openai_batch_line("batch_req_us1", "c1", body)])
    openai_client("https://us.api.openai.com/v1").batches.retrieve("batch_us")
  end

  define_case "openai batch responses: gpt-5.5-pro long context", instrument: :openai do
    body = responses_object(id: "resp_b2", model: "gpt-5.5-pro", usage: responses_usage(300_000, 10_000))
    stub_openai_batch(host: "api.openai.com", batch_id: "batch_pro", status: "completed", endpoint: "/v1/responses",
                      lines: [openai_batch_line("batch_req_pro1", "p1", body)])
    openai_client.batches.retrieve("batch_pro")
  end

  define_case "openai batch responses: gpt-5.4 long context with cached tokens", instrument: :openai do
    body = responses_object(id: "resp_b3", model: "gpt-5.4", usage: responses_usage(300_000, 2000, cached: 200_000))
    stub_openai_batch(host: "api.openai.com", batch_id: "batch_54l", status: "completed", endpoint: "/v1/responses",
                      lines: [openai_batch_line("batch_req_54l", "p1", body)])
    openai_client.batches.retrieve("batch_54l")
  end

  define_case "openai batch chat: azure openai v1 host", instrument: :openai do
    body = chat_completion(id: "chatcmpl_azb", model: "gpt-4o", usage: chat_usage(20_000, 2000))
    stub_json(:get, "#{AZURE_OPENAI}/v1/batches/batch_az",
              { id: "batch_az", object: "batch", endpoint: "/v1/chat/completions", status: "completed",
                input_file_id: "fi", output_file_id: "file_out_az", completion_window: "24h", created_at: 1 })
    WebMock.stub_request(:get, "#{AZURE_OPENAI}/v1/files/file_out_az/content")
           .to_return(status: 200, body: "#{JSON.generate(openai_batch_line('batch_req_az1', 'c1', body))}\n",
                      headers: { "Content-Type" => "application/octet-stream" })
    openai_client("#{AZURE_OPENAI}/v1/").batches.retrieve("batch_az")
  end

  define_case "openai batch chat: output file with blank and invalid lines", instrument: :openai do
    body = chat_completion(id: "chatcmpl_bl", model: "gpt-4o-mini", usage: chat_usage(1000, 100))
    stub_json(:get, "#{OPENAI_API}/batches/batch_bl",
              { id: "batch_bl", object: "batch", endpoint: "/v1/chat/completions", status: "completed",
                input_file_id: "fi", output_file_id: "file_out_bl", completion_window: "24h", created_at: 1 })
    output = "\n#{JSON.generate(openai_batch_line('batch_req_bl1', 'c1', body))}\n\n  \nnot json\n"
    WebMock.stub_request(:get, "#{OPENAI_API}/files/file_out_bl/content")
           .to_return(status: 200, body: output, headers: { "Content-Type" => "application/octet-stream" })
    openai_client.batches.retrieve("batch_bl")
  end

  define_case "anthropic batch: succeeded, errored and expired results", instrument: :anthropic do
    message = anthropic_message(id: "msg_b1", model: "claude-sonnet-4-5", usage: anthropic_usage(10_000, 500))
    error = { type: "error", error: { type: "invalid_request_error", message: "bad" } }
    stub_anthropic_batch("msgbatch_1", [anthropic_batch_result("r1", message),
                                        { custom_id: "r2", result: { type: "errored", error: error } },
                                        { custom_id: "r3", result: { type: "expired" } }])
    anthropic_client.messages.batches.results_streaming("msgbatch_1").each { nil }
  end

  define_case "anthropic batch: sonnet-4-6 result with us inference geo", instrument: :anthropic do
    usage = { input_tokens: 1000, output_tokens: 500, cache_read_input_tokens: 20_000, service_tier: "batch",
              inference_geo: "us" }
    message = anthropic_message(id: "msg_b2", model: "claude-sonnet-4-6", content: [], usage: usage)
    stub_anthropic_batch("msgbatch_2", [anthropic_batch_result("r1", message)])
    anthropic_client.messages.batches.results_streaming("msgbatch_2").each { nil }
  end

  define_case "anthropic batch: 1h cache writes with cache reads", instrument: :anthropic do
    usage = anthropic_usage(500, 800, cache_read: 30_000, cache_1h: 10_000, extra: { service_tier: "batch" })
    message = anthropic_message(id: "msg_b3", model: "claude-opus-4-6", usage: usage)
    stub_anthropic_batch("msgbatch_3", [anthropic_batch_result("r1", message)])
    anthropic_client.messages.batches.results_streaming("msgbatch_3").each { nil }
  end

  define_case "anthropic batch: result without a service tier", instrument: :anthropic do
    message = anthropic_message(id: "msg_b4", model: "claude-haiku-4-5",
                                usage: { input_tokens: 10_000, output_tokens: 1000 })
    stub_anthropic_batch("msgbatch_4", [anthropic_batch_result("r1", message)])
    anthropic_client.messages.batches.results_streaming("msgbatch_4").each { nil }
  end

  define_case "anthropic batch: web search requests", instrument: :anthropic do
    usage = { input_tokens: 10_000, output_tokens: 1000, service_tier: "batch",
              server_tool_use: { web_search_requests: 3 } }
    message = anthropic_message(id: "msg_b5", model: "claude-sonnet-4-5", usage: usage)
    stub_anthropic_batch("msgbatch_5", [anthropic_batch_result("r1", message)])
    anthropic_client.messages.batches.results_streaming("msgbatch_5").each { nil }
  end

  define_case "anthropic batch: results iterated twice", instrument: :anthropic do
    message = anthropic_message(id: "msg_b6", model: "claude-sonnet-4-5", usage: anthropic_usage(1000, 100))
    stub_anthropic_batch("msgbatch_6", [anthropic_batch_result("r1", message)])
    2.times { anthropic_client.messages.batches.results_streaming("msgbatch_6").each { nil } }
  end

  define_case "anthropic batch: result reporting the priority tier", instrument: :anthropic do
    message = anthropic_message(id: "msg_b7", model: "claude-sonnet-4-5",
                                usage: { input_tokens: 10_000, output_tokens: 1000, service_tier: "priority" })
    stub_anthropic_batch("msgbatch_7", [anthropic_batch_result("r1", message)])
    anthropic_client.messages.batches.results_streaming("msgbatch_7").each { nil }
  end

  define_case "openai batch chat: gpt-5.4 on the us host", instrument: :openai do
    body = chat_completion(id: "chatcmpl_us54", model: "gpt-5.4", usage: chat_usage(200_000, 20_000, cached: 50_000))
    stub_openai_batch(host: "us.api.openai.com", batch_id: "batch_us54", status: "completed",
                      endpoint: "/v1/chat/completions", lines: [openai_batch_line("batch_req_us54", "c1", body)])
    openai_client("https://us.api.openai.com/v1").batches.retrieve("batch_us54")
  end

  define_case "openai batch chat: default service tier in the result body", instrument: :openai do
    body = chat_completion(id: "chatcmpl_bst", model: "gpt-5.4", usage: chat_usage(10_000, 1000),
                           service_tier: "default")
    stub_openai_batch(host: "api.openai.com", batch_id: "batch_bst", status: "completed",
                      endpoint: "/v1/chat/completions", lines: [openai_batch_line("batch_req_bst", "c1", body)])
    openai_client.batches.retrieve("batch_bst")
  end

  define_case "openai batch images: batch without a model", instrument: :openai do
    body = { created: 1, data: [], usage: { input_tokens: 50, output_tokens: 1056, total_tokens: 1106 } }
    stub_openai_batch(host: "api.openai.com", batch_id: "batch_imgnm", status: "completed",
                      endpoint: "/v1/images/generations", lines: [openai_batch_line("batch_req_imgnm", "i1", body)])
    openai_client.batches.retrieve("batch_imgnm")
  end

  define_case "openai batch chat: body id repeated across results", instrument: :openai do
    lines = [
      openai_batch_line("batch_req_dup1", "c1",
                        chat_completion(id: "chatcmpl_same", model: "gpt-4o", usage: chat_usage(1000, 100))),
      openai_batch_line("batch_req_dup2", "c2",
                        chat_completion(id: "chatcmpl_same", model: "gpt-4o", usage: chat_usage(2000, 200)))
    ]
    stub_openai_batch(host: "api.openai.com", batch_id: "batch_dup", status: "completed",
                      endpoint: "/v1/chat/completions", lines: lines)
    openai_client.batches.retrieve("batch_dup")
  end

  define_case "anthropic batch: advisor iterations", instrument: :anthropic do
    message = anthropic_message(id: "msg_adv7", model: "claude-sonnet-5", usage: advisor_usage(service_tier: "batch"))
    stub_anthropic_batch("msgbatch_adv", [anthropic_batch_result("r1", message)])
    anthropic_client.messages.batches.results_streaming("msgbatch_adv").each { nil }
  end
end
