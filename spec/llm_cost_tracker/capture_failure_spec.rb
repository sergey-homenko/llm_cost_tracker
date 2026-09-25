# frozen_string_literal: true

require "spec_helper"
require "faraday"
require "openai"
require "anthropic"

RSpec.describe "Recording failures after the provider answered" do
  let(:shutdown) { Class.new(Interrupt) }
  let(:unpriced_model) { "ft:gpt-4o-mini:acme::abc123" }
  let(:aborted) { LlmCostTracker::TransactionAbortedError.new(ActiveRecord::Deadlocked.new("deadlock")) }

  before do
    establish_database_connection!
    create_lct_tables!
    [LlmCostTracker::Call, LlmCostTracker::CallLineItem, LlmCostTracker::CallTag, LlmCostTracker::CallRollup,
     LlmCostTracker::Ingestion::InboxEntry, LlmCostTracker::Ingestion::Lease].each(&:reset_column_information)
    WebMock.stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return do |request|
      model = JSON.parse(request.body)["model"]
      { status: 200, body: chat_body(model), headers: { "Content-Type" => "application/json" } }
    end
    WebMock.stub_request(:post, "https://api.openai.com/v1/chat/completions").with(body: /"stream":true/)
           .to_return(status: 200, body: chat_sse, headers: { "Content-Type" => "text/event-stream" })
  end

  after { disconnect_database! }

  def chat_body(model)
    { id: "chatcmpl_1", object: "chat.completion", created: 1, model: model,
      choices: [{ index: 0, message: { role: "assistant", content: "hi" }, finish_reason: "stop" }],
      usage: { prompt_tokens: 100, completion_tokens: 20, total_tokens: 120 } }.to_json
  end

  def chat_sse
    chunk = { id: "chatcmpl_s", object: "chat.completion.chunk", created: 1, model: "gpt-4o", choices: [],
              usage: { prompt_tokens: 100, completion_tokens: 20, total_tokens: 120 } }
    "data: #{chunk.to_json}\n\ndata: [DONE]\n\n"
  end

  def faraday(&response)
    Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter(:test) { |stub| stub.post("/v1/chat/completions", &response) }
    end
  end

  def faraday_call(model: "gpt-4o")
    faraday { [200, { "Content-Type" => "application/json" }, chat_body(model)] }
      .post("/v1/chat/completions", { model: model }.to_json)
  end

  def openai_chat(model: "gpt-4o")
    openai_client.chat.completions.create(model: model, messages: [{ role: "user", content: "hi" }])
  end

  def openai_stream
    openai_client.chat.completions.stream_raw(model: "gpt-4o", messages: [{ role: "user", content: "hi" }])
  end

  def openai_client
    OpenAI::Client.new(api_key: "test-key", max_retries: 0)
  end

  def track_stream_raising(error)
    LlmCostTracker.track_stream(provider: :openai, model: "gpt-4o") do |stream|
      stream.usage(input_tokens: 100, output_tokens: 20)
      raise error
    end
  end

  it "logs a recording failure from automatic capture and returns the response, while track raises it" do
    LlmCostTracker.configure do |c|
      c.ingestion.mode = :async
      c.instrument(:openai)
    end
    allow(LlmCostTracker::Ingestion::Worker).to receive(:ensure_started)
    allow(LlmCostTracker::Ingestion::Pool).to receive(:with_connection).and_raise(ActiveRecord::ConnectionTimeoutError)

    log = capture_log do
      expect(faraday_call.status).to eq(200)
      expect(openai_chat.id).to eq("chatcmpl_1")
    end

    expect(log.scan("could not checkout a database connection").size).to eq(2)
    expect do
      LlmCostTracker.track(provider: :openai, model: "gpt-4o", tokens: { input_tokens: 1, output_tokens: 1 })
    end.to raise_error(LlmCostTracker::Error, /could not checkout/)
  end

  it "records an unpriced call under :raise before raising UnknownPricingError" do
    LlmCostTracker.configure do |c|
      c.pricing.unknown_model_behavior = :raise
      c.instrument(:openai)
    end

    expect { faraday_call(model: unpriced_model) }.to raise_error(LlmCostTracker::UnknownPricingError)
    expect { openai_chat(model: unpriced_model) }.to raise_error(LlmCostTracker::UnknownPricingError)
    expect(LlmCostTracker::Call.pluck(:model, :input_tokens, :cost_status)).to eq([[unpriced_model, 100, "unknown"]] * 2)
  end

  it "raises TransactionAbortedError over the network error when recording an interrupted stream loses the transaction" do
    allow(LlmCostTracker::Tracker).to receive(:record).and_raise(aborted)

    expect do
      faraday { raise Faraday::ConnectionFailed, "died" }
        .post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json) do |request|
          request.options.on_data = proc { |_chunk, _size, _env| }
        end
    end.to raise_error(LlmCostTracker::TransactionAbortedError) { |error| expect(error.cause).to be_a(Faraday::ConnectionFailed) }
  end

  describe "an exception raised by the caller mid-stream" do
    it "wins over a budget error from recording the SDK stream, which is still recorded as errored" do
      LlmCostTracker.configure do |c|
        c.budgets.per_call = 0.000001
        c.budgets.exceeded_behavior = :raise
        c.instrument(:openai)
      end

      log = capture_log { expect { openai_stream.each { raise shutdown } }.to raise_error(shutdown) }

      expect(LlmCostTracker::CallTag.where(key: "stream_errored").count).to eq(1)
      expect(log).to include("Recording an errored stream raised LlmCostTracker::BudgetExceededError")
    end

    it "wins over a failed track_stream write" do
      allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_raise(ActiveRecord::StatementInvalid, "db down")

      log = capture_log { expect { track_stream_raising(shutdown) }.to raise_error(shutdown) }

      expect(log).to include("Recording an errored stream raised ActiveRecord::StatementInvalid: db down")
    end

    it "loses to TransactionAbortedError, which keeps it as the cause" do
      LlmCostTracker.configure { |c| c.instrument(:openai) }
      allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_raise(aborted)

      expect { openai_stream.each { raise shutdown } }
        .to raise_error(LlmCostTracker::TransactionAbortedError) { |error| expect(error.cause).to be_a(shutdown) }
      expect { track_stream_raising(shutdown) }
        .to raise_error(LlmCostTracker::TransactionAbortedError) { |error| expect(error.cause).to be_a(shutdown) }
    end
  end

  describe "batch results under :raise" do
    def openai_batch_line(id, model)
      { id: "req_#{id}", custom_id: id, response: { status_code: 200, body: {
        id: "chatcmpl_#{id}", object: "chat.completion", created: 1, model: model,
        choices: [{ index: 0, message: { role: "assistant", content: "hi" }, finish_reason: "stop" }],
        usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
      } } }.to_json
    end

    def anthropic_batch_line(id, model)
      { custom_id: id, result: { type: "succeeded", message: {
        id: "msg_#{id}", type: "message", role: "assistant", model: model, content: [{ type: "text", text: "hi" }],
        stop_reason: "end_turn", usage: { input_tokens: 10, output_tokens: 5 }
      } } }.to_json
    end

    before do
      LlmCostTracker::Integrations::Openai::BatchCapture.instance_variable_set(:@dedup, nil)
      LlmCostTracker.configure do |c|
        c.pricing.unknown_model_behavior = :raise
        c.instrument(:openai)
        c.instrument(:anthropic)
      end
    end

    it "records every OpenAI result before raising once" do
      WebMock.stub_request(:get, "https://api.openai.com/v1/batches/batch_done").to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: { id: "batch_done", object: "batch", status: "completed", input_file_id: "file_in",
                output_file_id: "file_out", endpoint: "/v1/chat/completions", completion_window: "24h",
                created_at: 1 }.to_json
      )
      WebMock.stub_request(:get, "https://api.openai.com/v1/files/file_out/content").to_return(
        status: 200, headers: { "Content-Type" => "application/binary" },
        body: [openai_batch_line("a", "gpt-4o"), openai_batch_line("b", unpriced_model), "{not json",
               openai_batch_line("c", "gpt-4o-mini")].join("\n")
      )

      expect { openai_client.batches.retrieve("batch_done") }.to raise_error(LlmCostTracker::UnknownPricingError)
      expect(LlmCostTracker::Call.pluck(:provider_response_id)).to contain_exactly("chatcmpl_a", "chatcmpl_b",
                                                                                  "chatcmpl_c")
      expect(openai_client.batches.retrieve("batch_done").id).to eq("batch_done")
      expect(WebMock).to have_requested(:get, "https://api.openai.com/v1/files/file_out/content").once
    end

    it "hands every Anthropic result to the caller and records it before raising once" do
      WebMock.stub_request(:get, %r{https://api\.anthropic\.com/v1/messages/batches/batch_xyz/results}).to_return(
        status: 200, headers: { "Content-Type" => "application/x-jsonl" },
        body: [anthropic_batch_line("a", "claude-sonnet-4-5"), anthropic_batch_line("b", "claude-custom-1"),
               anthropic_batch_line("c", "claude-sonnet-4-5")].join("\n")
      )
      results = Anthropic::Client.new(api_key: "test-key", max_retries: 0).messages.batches.results_streaming("batch_xyz")
      seen = []

      expect { results.each { |result| seen << result.custom_id } }.to raise_error(LlmCostTracker::UnknownPricingError)
      expect(seen).to eq(%w[a b c])
      expect(LlmCostTracker::Call.count).to eq(3)
    end
  end

  it "warns at boot, prices from bundled rates, and fails doctor when pricing.file does not exist" do
    log = capture_log { LlmCostTracker.configure { |c| c.pricing.file = "/nonexistent/prices.yml" } }

    expect(log).to include("pricing.file /nonexistent/prices.yml does not exist")
    expect(faraday_call.status).to eq(200)
    expect(LlmCostTracker::Call.sole.pricing_snapshot.fetch("source")).to eq("bundled")
    expect(LlmCostTracker::Doctor::PriceCheck.new.call).to have_attributes(status: :error)
  end
end
