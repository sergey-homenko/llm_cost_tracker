# frozen_string_literal: true

require "spec_helper"
require "faraday"
require "openai"
require "anthropic"
require "faraday"

RSpec.describe "Recording fetched results once" do
  let(:openai) { OpenAI::Client.new(api_key: "test-key", max_retries: 0) }
  let(:anthropic) { Anthropic::Client.new(api_key: "test-key", max_retries: 0) }

  before do
    establish_database_connection!
    create_lct_tables!
    [LlmCostTracker::Call, LlmCostTracker::CallLineItem, LlmCostTracker::CallTag, LlmCostTracker::CallRollup,
     LlmCostTracker::Ingestion::InboxEntry, LlmCostTracker::Ingestion::Lease].each(&:reset_column_information)
    LlmCostTracker::Integrations::Openai::BatchCapture.instance_variable_set(:@dedup, nil)
    allow(LlmCostTracker::Ingestion::Worker).to receive(:ensure_started)
  end

  after do
    LlmCostTracker::Ingestion::Worker.shutdown!
    disconnect_database!
  end

  def configure!(mode)
    LlmCostTracker.configure do |config|
      config.ingestion.mode = mode
      config.instrument(:openai, :anthropic)
    end
  end

  # A second process starts with an empty in-memory set of captured batches.
  def in_another_process
    LlmCostTracker::Integrations::Openai::BatchCapture.instance_variable_set(:@dedup, nil)
    yield
  end

  def ledger
    LlmCostTracker::Ingestion::Worker.flush!(timeout: 5)
    [LlmCostTracker::Call.order(:provider_response_id).pluck(:provider_response_id),
     LlmCostTracker::Call.sum(:total_cost)]
  end

  def stub_openai_batch
    WebMock.stub_request(:get, "https://api.openai.com/v1/batches/batch_1").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { id: "batch_1", object: "batch", endpoint: "/v1/chat/completions", status: "completed",
              input_file_id: "file_in", output_file_id: "file_out", completion_window: "24h", created_at: 1 }.to_json
    )
    lines = (1..3).map do |index|
      { id: "batch_req_#{index}", custom_id: "r#{index}", response: { status_code: 200, body: {
        id: "chatcmpl_#{index}", object: "chat.completion", created: 1, model: "gpt-4o-mini-2024-07-18",
        choices: [], usage: { prompt_tokens: 1_000_000, completion_tokens: 0, total_tokens: 1_000_000 }
      } } }.to_json
    end
    WebMock.stub_request(:get, "https://api.openai.com/v1/files/file_out/content").to_return(
      status: 200, headers: { "Content-Type" => "application/binary" }, body: lines.join("\n")
    )
  end

  # gpt-4o-mini Batch input: $0.075 per 1M tokens.
  let(:openai_batch) { [%w[chatcmpl_1 chatcmpl_2 chatcmpl_3], BigDecimal("0.225")] }

  it "stores each OpenAI batch result once when another process retrieves it before the inbox drains" do
    configure!(:async)
    stub_openai_batch

    openai.batches.retrieve("batch_1")
    in_another_process { openai.batches.retrieve("batch_1") }

    expect(ledger).to eq(openai_batch)
  end

  it "stores each OpenAI batch result once when a concurrent retrieve passed the ledger check first" do
    configure!(:inline)
    stub_openai_batch
    openai.batches.retrieve("batch_1")
    allow(LlmCostTracker::Call).to receive(:already_recorded?).and_return(false)

    in_another_process { openai.batches.retrieve("batch_1") }

    expect(ledger).to eq(openai_batch)
  end

  it "stores an Anthropic batch result once when the results are read twice before the inbox drains" do
    configure!(:async)
    result = { custom_id: "r1", result: { type: "succeeded", message: {
      id: "msg_1", type: "message", role: "assistant", model: "claude-haiku-4-5", content: [],
      stop_reason: "end_turn", stop_sequence: nil, usage: { input_tokens: 1_000_000, output_tokens: 0 }
    } } }
    WebMock.stub_request(:get, %r{https://api\.anthropic\.com/v1/messages/batches/msgbatch_1/results}).to_return(
      status: 200, headers: { "Content-Type" => "application/x-jsonl" }, body: "#{result.to_json}\n"
    )

    2.times { anthropic.messages.batches.results_streaming("msgbatch_1").each { |_| nil } }

    # Claude Haiku 4.5 Batch input: $0.50 per 1M tokens.
    expect(ledger).to eq([%w[msg_1], BigDecimal("0.5")])
  end

  let(:background_response) do
    { id: "resp_bg", object: "response", model: "o3-pro", status: "completed", background: true,
      created_at: 1, output: [], usage: { input_tokens: 1_000, output_tokens: 500, total_tokens: 1_500 } }
  end

  def stub_background_retrieve
    WebMock.stub_request(:get, "https://api.openai.com/v1/responses/resp_bg").to_return(
      status: 200, headers: { "Content-Type" => "application/json" }, body: background_response.to_json
    )
  end

  def stream_background_response
    completed = { type: "response.completed", sequence_number: 1, response: background_response }
    WebMock.stub_request(:post, "https://api.openai.com/v1/responses").to_return(
      status: 200, headers: { "Content-Type" => "text/event-stream" },
      body: "event: response.completed\ndata: #{completed.to_json}\n\n"
    )
    openai.responses.stream_raw(model: "o3-pro", input: "hi", background: true).each { |_| nil }
  end

  def drop_background_stream
    queued = background_response.merge(status: "queued", usage: nil)
    body = [["response.created", queued], ["response.in_progress", queued.merge(status: "in_progress")]]
           .each_with_index.map do |(type, response), index|
      "event: #{type}\ndata: #{{ type: type, sequence_number: index, response: response }.to_json}\n\n"
    end
    WebMock.stub_request(:post, "https://api.openai.com/v1/responses").to_return(
      status: 200, headers: { "Content-Type" => "text/event-stream" }, body: body.join
    )
    openai.responses.stream_raw(model: "o3-pro", input: "hi", background: true).each { |_| nil }
  end

  # ruby-openai's connection: its response middleware, then the app's `f.use :llm_cost_tracker`.
  let(:ruby_openai) do
    Faraday.new(url: "https://api.openai.com") do |f|
      f.response :raise_error
      f.response :json
      f.use :llm_cost_tracker
    end
  end

  # o3-pro: $20 input and $80 output per 1M tokens.
  let(:background_ledger) { [%w[resp_bg], BigDecimal("0.06")] }

  %i[inline async].each do |mode|
    it "stores a background response once however often a finished response is polled (#{mode})" do
      configure!(mode)
      stub_background_retrieve

      2.times { openai.responses.retrieve("resp_bg") }
      in_another_process { openai.responses.retrieve("resp_bg") }

      expect(ledger).to eq(background_ledger)
    end

    it "stores a background response once when it is streamed to completion and polled (#{mode})" do
      configure!(mode)
      stub_background_retrieve

      stream_background_response
      openai.responses.retrieve("resp_bg")

      expect(ledger).to eq(background_ledger)
    end

    it "prices a background response whose stream ended early when a poll sees it finished (#{mode})" do
      configure!(mode)
      stub_background_retrieve

      drop_background_stream
      2.times { openai.responses.retrieve("resp_bg") }

      # The dropped stream keeps its usage-unknown $0 row next to the priced one.
      expect(ledger).to eq([%w[resp_bg resp_bg], BigDecimal("0.06")])
    end

    it "stores a background response created and polled through the Faraday middleware once (#{mode})" do
      configure!(mode)
      WebMock.stub_request(:post, "https://api.openai.com/v1/responses").to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: background_response.merge(status: "queued", usage: nil).to_json
      )
      stub_background_retrieve
      expect(LlmCostTracker::Logging).not_to receive(:warn)

      ruby_openai.post("/v1/responses", { model: "o3-pro", input: "hi", background: true }.to_json,
                       "Content-Type" => "application/json")
      2.times { ruby_openai.get("/v1/responses/resp_bg") }

      expect(ledger).to eq(background_ledger)
      # Like the SDK's responses.retrieve, a poll stores no latency.
      expect(LlmCostTracker::Call.pluck(:latency_ms)).to eq([nil])
    end
  end

  it "drops a streamed background response that a poll already stored, without a warning" do
    configure!(:inline)
    stub_background_retrieve
    openai.responses.retrieve("resp_bg")
    expect(LlmCostTracker::Logging).not_to receive(:warn)

    stream_background_response

    expect(ledger).to eq(background_ledger)
  end

  it "stores a background Gemini interaction once, from the first GET that returns it finished" do
    configure!(:inline)
    url = "https://generativelanguage.googleapis.com/v1beta/interactions"
    running = { id: "v1_bg", model: "gemini-3.1-pro-preview", status: "in_progress" }
    finished = running.merge(status: "completed", usage: { total_input_tokens: 20_000, total_output_tokens: 4_000,
                                                            total_thought_tokens: 6_000, total_tokens: 30_000 })
    json = { status: 200, headers: { "Content-Type" => "application/json" } }
    WebMock.stub_request(:post, url).to_return(json.merge(body: running.to_json))
    WebMock.stub_request(:get, "#{url}/v1_bg").to_return(
      json.merge(body: running.merge(usage: { total_input_tokens: 20_000, total_tokens: 20_000 }).to_json),
      json.merge(body: finished.to_json)
    )
    gemini = Faraday.new { |f| f.use :llm_cost_tracker }
    expect(LlmCostTracker::Logging).not_to receive(:warn)

    gemini.post(url, { model: "gemini-3.1-pro-preview", input: "Research this", background: true }.to_json)
    3.times { gemini.get("#{url}/v1_bg") }

    # Gemini 3.1 Pro Preview, prompts up to 200k: $2.00 input and $12.00 output (thinking included) per 1M tokens.
    expect(ledger).to eq([%w[v1_bg], BigDecimal("0.16")])
  end
end
