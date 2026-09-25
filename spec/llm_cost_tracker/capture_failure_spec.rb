# frozen_string_literal: true

require "spec_helper"
require "faraday"
require "openai"
require "anthropic"
require "tempfile"

RSpec.describe "Recording failures after the provider answered" do
  let(:host_error) { Class.new(StandardError) }
  let(:unpriced_model) { "ft:gpt-4o-mini:acme::abc123" }

  before do
    establish_database_connection!
    create_lct_tables!
    [LlmCostTracker::Call, LlmCostTracker::CallLineItem, LlmCostTracker::CallTag, LlmCostTracker::CallRollup,
     LlmCostTracker::Ingestion::InboxEntry, LlmCostTracker::Ingestion::Lease].each(&:reset_column_information)
  end

  after { disconnect_database! }

  def chat_body(model)
    { id: "chatcmpl_1", object: "chat.completion", created: 1, model: model,
      choices: [{ index: 0, message: { role: "assistant", content: "hi" }, finish_reason: "stop" }],
      usage: { prompt_tokens: 100, completion_tokens: 20, total_tokens: 120 } }.to_json
  end

  def chat_sse(model)
    first = { id: "chatcmpl_s", object: "chat.completion.chunk", created: 1, model: model,
              choices: [{ index: 0, delta: { content: "hi" } }] }
    last = { id: "chatcmpl_s", object: "chat.completion.chunk", created: 1, model: model, choices: [],
             usage: { prompt_tokens: 100, completion_tokens: 20, total_tokens: 120 } }
    "data: #{first.to_json}\n\ndata: #{last.to_json}\n\ndata: [DONE]\n\n"
  end

  def faraday_connection
    Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") do |env|
          request = JSON.parse(env.body)
          if request["stream"]
            [200, { "Content-Type" => "text/event-stream" }, chat_sse(request["model"])]
          else
            [200, { "Content-Type" => "application/json" }, chat_body(request["model"])]
          end
        end
      end
    end
  end

  def faraday_call(model: "gpt-4o", stream: false)
    faraday_connection.post("/v1/chat/completions", { model: model, stream: stream, messages: [] }.to_json)
  end

  def stub_openai_sdk
    WebMock.stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return do |request|
      body = JSON.parse(request.body)
      if body["stream"]
        { status: 200, body: chat_sse(body["model"]), headers: { "Content-Type" => "text/event-stream" } }
      else
        { status: 200, body: chat_body(body["model"]), headers: { "Content-Type" => "application/json" } }
      end
    end
  end

  def openai_client
    OpenAI::Client.new(api_key: "test-key", max_retries: 0)
  end

  def cause_chain(error)
    chain = []
    while error
      chain << error
      error = error.cause
    end
    chain
  end

  describe "Faraday middleware" do
    it "returns the provider response and logs when recording fails with an internal gem error" do
      LlmCostTracker.configure { |c| c.enabled = true }
      allow(LlmCostTracker::Tracker).to receive(:record).and_raise(LlmCostTracker::Error, "internal failure")

      response = nil
      log = capture_log { response = faraday_call }

      expect(response.status).to eq(200)
      expect(log).to include("LlmCostTracker::Error: internal failure")
    end

    it "returns the provider response when the async inbox cannot lend a connection" do
      LlmCostTracker.configure { |c| c.ingestion.mode = :async }
      allow(LlmCostTracker::Ingestion::Worker).to receive(:ensure_started)
      allow(LlmCostTracker::Ingestion::Pool).to receive(:with_connection).and_raise(ActiveRecord::ConnectionTimeoutError)

      response = nil
      log = capture_log { response = faraday_call }

      expect(response.status).to eq(200)
      expect(log).to include("could not checkout a database connection")
    end

    it "records the call before raising UnknownPricingError" do
      LlmCostTracker.configure { |c| c.pricing.unknown_model_behavior = :raise }

      expect { faraday_call(model: unpriced_model) }.to raise_error(LlmCostTracker::UnknownPricingError)

      call = LlmCostTracker::Call.sole
      expect(call).to have_attributes(model: unpriced_model, input_tokens: 100, output_tokens: 20,
                                      cost_status: "unknown", total_cost: nil)
    end

    it "records a streamed call before raising UnknownPricingError, with its real usage" do
      LlmCostTracker.configure { |c| c.pricing.unknown_model_behavior = :raise }

      expect { faraday_call(model: unpriced_model, stream: true) }.to raise_error(LlmCostTracker::UnknownPricingError)

      call = LlmCostTracker::Call.sole
      expect(call).to have_attributes(stream: true, input_tokens: 100, output_tokens: 20)
      expect(LlmCostTracker::CallTag.where(key: "stream_interrupted")).to be_empty
    end

    it "keeps raising TransactionAbortedError, because the caller's transaction is gone" do
      LlmCostTracker.configure { |c| c.enabled = true }
      allow(LlmCostTracker::Ledger::Store).to receive(:insert)
        .and_raise(LlmCostTracker::TransactionAbortedError.new(ActiveRecord::Deadlocked.new("deadlock")))

      expect { faraday_call }.to raise_error(LlmCostTracker::TransactionAbortedError)
    end

    it "raises TransactionAbortedError over the network error when recording an interrupted stream loses the transaction" do
      aborted = LlmCostTracker::TransactionAbortedError.new(ActiveRecord::Deadlocked.new("deadlock"))
      allow(LlmCostTracker::Tracker).to receive(:record).and_raise(aborted)
      connection = Faraday.new(url: "https://api.openai.com") do |f|
        f.use :llm_cost_tracker
        f.adapter(:test) { |stub| stub.post("/v1/chat/completions") { raise Faraday::ConnectionFailed, "died" } }
      end

      expect do
        connection.post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json) do |request|
          request.options.on_data = proc { |_chunk, _size, _env| }
        end
      end.to raise_error(LlmCostTracker::TransactionAbortedError) { |error| expect(error.cause).to be_a(Faraday::ConnectionFailed) }
    end

    it "raises the network error, not a budget error, when a stream dies after the budget is spent" do
      LlmCostTracker.configure do |c|
        c.budgets.monthly = 0.000001
        c.budgets.exceeded_behavior = :raise
      end
      expect do
        LlmCostTracker.track(provider: :openai, model: "gpt-4o", tokens: { input_tokens: 1_000, output_tokens: 0 })
      end.to raise_error(LlmCostTracker::BudgetExceededError)
      allow(LlmCostTracker::Logging).to receive(:warn)
      connection = Faraday.new(url: "https://api.openai.com") do |f|
        f.use :llm_cost_tracker
        f.adapter(:test) { |stub| stub.post("/v1/chat/completions") { raise Faraday::ConnectionFailed, "died" } }
      end

      expect do
        connection.post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json) do |request|
          request.options.on_data = proc { |_chunk, _size, _env| }
        end
      end.to raise_error(Faraday::ConnectionFailed)
      expect(LlmCostTracker::Logging).to have_received(:warn)
        .with(/Error recording interrupted stream: LlmCostTracker::BudgetExceededError/)
    end

    it "keeps raising a post-spend BudgetExceededError after recording" do
      LlmCostTracker.configure do |c|
        c.budgets.per_call = 0.000001
        c.budgets.exceeded_behavior = :raise
      end

      expect { faraday_call }.to raise_error(LlmCostTracker::BudgetExceededError)
      expect(LlmCostTracker::Call.count).to eq(1)
    end

    it "prices from bundled rates when pricing.file does not exist" do
      LlmCostTracker.configure { |c| c.pricing.file = "/nonexistent/llm_cost_tracker_prices.yml" }

      expect(faraday_call.status).to eq(200)
      call = LlmCostTracker::Call.sole
      expect(call.total_cost).to be_positive
      expect(call.pricing_snapshot.fetch("source")).to eq("bundled")
    end
  end

  describe "SDK integrations" do
    before { stub_openai_sdk }

    it "returns the SDK response when recording fails with an internal gem error" do
      LlmCostTracker.configure { |c| c.instrument(:openai) }
      allow(LlmCostTracker::Tracker).to receive(:record).and_raise(LlmCostTracker::Error, "internal failure")

      response = nil
      log = capture_log do
        response = openai_client.chat.completions.create(model: "gpt-4o", messages: [{ role: "user", content: "hi" }])
      end

      expect(response.id).to eq("chatcmpl_1")
      expect(log).to include("openai integration failed to record usage: LlmCostTracker::Error: internal failure")
    end

    it "records a blocking call before raising UnknownPricingError" do
      LlmCostTracker.configure do |c|
        c.pricing.unknown_model_behavior = :raise
        c.instrument(:openai)
      end

      expect do
        openai_client.chat.completions.create(model: unpriced_model, messages: [{ role: "user", content: "hi" }])
      end.to raise_error(LlmCostTracker::UnknownPricingError)
      expect(LlmCostTracker::Call.sole).to have_attributes(model: unpriced_model, cost_status: "unknown")
    end

    it "records a stream before raising UnknownPricingError from iteration" do
      LlmCostTracker.configure do |c|
        c.pricing.unknown_model_behavior = :raise
        c.instrument(:openai)
      end
      stream = openai_client.chat.completions.stream_raw(model: unpriced_model, messages: [{ role: "user", content: "hi" }])

      expect { stream.each { |_chunk| nil } }.to raise_error(LlmCostTracker::UnknownPricingError)
      expect(LlmCostTracker::Call.sole).to have_attributes(stream: true, input_tokens: 100, output_tokens: 20)
    end

    it "does not replace the exception the host raised mid-stream with a recording error" do
      LlmCostTracker.configure do |c|
        c.budgets.per_call = 0.000001
        c.budgets.exceeded_behavior = :raise
        c.instrument(:openai)
      end
      allow(LlmCostTracker::Logging).to receive(:warn)
      stream = openai_client.chat.completions.stream_raw(model: "gpt-4o", messages: [{ role: "user", content: "hi" }])

      expect do
        stream.each { |chunk| raise host_error, "render failed" if chunk.usage }
      end.to raise_error(host_error, "render failed")
      expect(LlmCostTracker::Call.count).to eq(1)
      expect(LlmCostTracker::Logging).to have_received(:warn)
        .with(/recorded an errored stream and did not raise LlmCostTracker::BudgetExceededError/)
    end
  end

  describe "a lost host transaction while an exception is already in flight" do
    let(:aborted) { LlmCostTracker::TransactionAbortedError.new(ActiveRecord::Deadlocked.new("deadlock")) }

    it "logs, and keeps the host's exception, when an errored SDK stream cannot be recorded" do
      stub_openai_sdk
      LlmCostTracker.configure { |c| c.instrument(:openai) }
      allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_raise(ActiveRecord::StatementInvalid, "db down")
      allow(LlmCostTracker::Logging).to receive(:warn)
      stream = openai_client.chat.completions.stream_raw(model: "gpt-4o", messages: [{ role: "user", content: "hi" }])

      expect { stream.each { |chunk| raise host_error, "render failed" if chunk.usage } }
        .to raise_error(host_error, "render failed")
      expect(LlmCostTracker::Logging).to have_received(:warn).with(/failed to record usage: .*db down/)
    end

    it "logs, and keeps the block's exception, when an errored track_stream cannot be recorded" do
      allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_raise(ActiveRecord::StatementInvalid, "db down")
      allow(LlmCostTracker::Logging).to receive(:warn)

      expect do
        LlmCostTracker.track_stream(provider: :openai, model: "gpt-4o") do |stream|
          stream.usage(input_tokens: 100, output_tokens: 20)
          raise host_error, "client failed"
        end
      end.to raise_error(host_error, "client failed")
      expect(LlmCostTracker::Logging).to have_received(:warn).with(/track_stream could not record .*db down/)
    end

    it "raises TransactionAbortedError over the host's exception from an SDK stream" do
      stub_openai_sdk
      LlmCostTracker.configure { |c| c.instrument(:openai) }
      allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_raise(aborted)
      stream = openai_client.chat.completions.stream_raw(model: "gpt-4o", messages: [{ role: "user", content: "hi" }])

      expect { stream.each { |chunk| raise host_error, "render failed" if chunk.usage } }
        .to raise_error(LlmCostTracker::TransactionAbortedError) { |error| expect(error.cause).to be_a(host_error) }
    end

    it "keeps the block's exception in the cause chain when a real deadlock loses the host transaction" do
      skip "simulates InnoDB deadlock semantics with PostgreSQL" unless
        LlmCostTracker::Ledger::Schema::Adapter.postgresql?(ActiveRecord::Base.connection)
      connection = ActiveRecord::Base.connection
      allow(connection).to receive(:savepoint_errors_invalidate_transactions?).and_return(true)
      allow(LlmCostTracker::Call).to receive(:insert_all!) do
        connection.execute("DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '40P01', MESSAGE = 'Deadlock found'; END $$")
      rescue ActiveRecord::Deadlocked
        connection.raw_connection.exec("ROLLBACK")
        connection.raw_connection.exec("BEGIN")
        raise
      end

      expect do
        ActiveRecord::Base.transaction do
          LlmCostTracker.track_stream(provider: :openai, model: "gpt-4o") do |stream|
            stream.usage(input_tokens: 100, output_tokens: 20)
            raise host_error, "client failed"
          end
        end
      end.to raise_error(LlmCostTracker::TransactionAbortedError) { |error|
        expect(cause_chain(error)).to include(an_instance_of(ActiveRecord::Deadlocked), an_instance_of(host_error))
      }
    end

    it "raises TransactionAbortedError over the block's exception from track_stream" do
      allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_raise(aborted)

      expect do
        LlmCostTracker.track_stream(provider: :openai, model: "gpt-4o") do |stream|
          stream.usage(input_tokens: 100, output_tokens: 20)
          raise host_error, "client failed"
        end
      end.to raise_error(LlmCostTracker::TransactionAbortedError) { |error| expect(error.cause).to be_a(host_error) }
    end
  end

  describe "batch results" do
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

    def stub_openai_batch(*lines)
      WebMock.stub_request(:get, "https://api.openai.com/v1/batches/batch_done").to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: { id: "batch_done", object: "batch", status: "completed", input_file_id: "file_in",
                output_file_id: "file_out", endpoint: "/v1/chat/completions", completion_window: "24h",
                created_at: 1 }.to_json
      )
      WebMock.stub_request(:get, "https://api.openai.com/v1/files/file_out/content").to_return(
        status: 200, headers: { "Content-Type" => "application/binary" }, body: lines.join("\n")
      )
    end

    def stub_anthropic_batch(*lines)
      WebMock.stub_request(:get, %r{https://api\.anthropic\.com/v1/messages/batches/batch_xyz/results}).to_return(
        status: 200, headers: { "Content-Type" => "application/x-jsonl" }, body: lines.join("\n")
      )
    end

    def anthropic_results
      Anthropic::Client.new(api_key: "test-key", max_retries: 0).messages.batches.results_streaming("batch_xyz")
    end

    let(:per_call_budget) { nil }

    before do
      LlmCostTracker::Integrations::Openai::BatchCapture.instance_variable_set(:@dedup, nil)
      LlmCostTracker.configure do |c|
        c.pricing.unknown_model_behavior = :raise
        if per_call_budget
          c.budgets.per_call = per_call_budget
          c.budgets.exceeded_behavior = :raise
        end
        c.instrument(:openai)
        c.instrument(:anthropic)
      end
    end

    it "records every OpenAI batch result before raising once for the unpriced ones" do
      stub_openai_batch(openai_batch_line("a", "gpt-4o"), openai_batch_line("b", unpriced_model), "{not json",
                        openai_batch_line("c", "gpt-4o-mini"))

      expect { openai_client.batches.retrieve("batch_done") }.to raise_error(LlmCostTracker::UnknownPricingError)
      expect(LlmCostTracker::Call.pluck(:provider_response_id)).to contain_exactly("chatcmpl_a", "chatcmpl_b",
                                                                                  "chatcmpl_c")
      expect(openai_client.batches.retrieve("batch_done").id).to eq("batch_done")
      expect(WebMock).to have_requested(:get, "https://api.openai.com/v1/files/file_out/content").once
    end

    context "when results cross a per-call budget" do
      let(:per_call_budget) { 0.000001 }

      it "records every OpenAI batch result before raising once" do
        stub_openai_batch(openai_batch_line("a", "gpt-4o"), openai_batch_line("b", "gpt-4o"))

        expect { openai_client.batches.retrieve("batch_done") }.to raise_error(LlmCostTracker::BudgetExceededError)
        expect(LlmCostTracker::Call.count).to eq(2)
      end

      it "hands every Anthropic batch result to the caller before raising once" do
        stub_anthropic_batch(anthropic_batch_line("a", "claude-sonnet-4-5"),
                             anthropic_batch_line("b", "claude-sonnet-4-5"))
        seen = []

        expect { anthropic_results.each { |result| seen << result.custom_id } }
          .to raise_error(LlmCostTracker::BudgetExceededError)
        expect(seen).to eq(%w[a b])
        expect(LlmCostTracker::Call.count).to eq(2)
      end
    end

    it "still raises the deferred error and retries the batch when another result fails to record" do
      stub_openai_batch(openai_batch_line("a", unpriced_model), openai_batch_line("b", "gpt-4o"))
      allow(LlmCostTracker::Logging).to receive(:warn)
      failures = 0
      allow(LlmCostTracker::Tracker).to receive(:record).and_wrap_original do |original, **kwargs, &block|
        if kwargs[:event].model == "gpt-4o" && (failures += 1) == 1
          raise ActiveRecord::ConnectionTimeoutError, "pool busy"
        end

        original.call(**kwargs, &block)
      end

      expect { openai_client.batches.retrieve("batch_done") }.to raise_error(LlmCostTracker::UnknownPricingError)
      expect(LlmCostTracker::Call.pluck(:provider_response_id)).to eq(["chatcmpl_a"])
      expect(openai_client.batches.retrieve("batch_done").id).to eq("batch_done")
      expect(LlmCostTracker::Call.pluck(:provider_response_id)).to contain_exactly("chatcmpl_a", "chatcmpl_b")
      expect(LlmCostTracker::Logging).to have_received(:warn).with(/OpenAI batch result could not be recorded/)
    end

    it "hands every Anthropic batch result to the caller before raising for the unpriced ones" do
      stub_anthropic_batch(anthropic_batch_line("a", "claude-sonnet-4-5"), anthropic_batch_line("b", "claude-custom-1"),
                           anthropic_batch_line("c", "claude-sonnet-4-5"))
      seen = []

      expect { anthropic_results.each { |result| seen << result.custom_id } }
        .to raise_error(LlmCostTracker::UnknownPricingError)
      expect(seen).to eq(%w[a b c])
      expect(LlmCostTracker::Call.count).to eq(3)
    end

    it "lets the caller's own exception win over a deferred Anthropic batch error" do
      stub_anthropic_batch(anthropic_batch_line("a", "claude-custom-1"), anthropic_batch_line("b", "claude-sonnet-4-5"))

      expect { anthropic_results.each { raise host_error, "render failed" } }.to raise_error(host_error)
      expect(LlmCostTracker::Call.count).to eq(1)
    end

    it "raises TransactionAbortedError from an OpenAI batch as soon as the host transaction is lost" do
      stub_openai_batch(openai_batch_line("a", "gpt-4o"), openai_batch_line("b", "gpt-4o"))
      allow(LlmCostTracker::Tracker).to receive(:record)
        .and_raise(LlmCostTracker::TransactionAbortedError.new(ActiveRecord::Deadlocked.new("deadlock")))

      expect { openai_client.batches.retrieve("batch_done") }.to raise_error(LlmCostTracker::TransactionAbortedError)
      expect(LlmCostTracker::Tracker).to have_received(:record).once
    end

    it "raises the deferred error when the caller stops reading Anthropic batch results early" do
      stub_anthropic_batch(anthropic_batch_line("a", "claude-custom-1"), anthropic_batch_line("b", "claude-sonnet-4-5"))

      expect { anthropic_results.first }.to raise_error(LlmCostTracker::UnknownPricingError)
      expect { anthropic_results.each { break } }.not_to raise_error
      expect(LlmCostTracker::Call.count).to eq(1)
    end

  end

  describe "non-StandardError exceptions mid-stream" do
    let(:shutdown) { Class.new(Interrupt) }

    before do
      stub_openai_sdk
      LlmCostTracker.configure do |c|
        c.budgets.per_call = 0.000001
        c.budgets.exceeded_behavior = :raise
        c.instrument(:openai)
      end
    end

    it "lets a worker shutdown signal through an SDK stream and tags the call as errored" do
      stream = openai_client.chat.completions.stream_raw(model: "gpt-4o", messages: [{ role: "user", content: "hi" }])

      expect { stream.each { |chunk| raise shutdown if chunk.usage } }.to raise_error(shutdown)
      expect(LlmCostTracker::CallTag.where(key: "stream_errored").count).to eq(1)
    end

    it "records a track_stream block interrupted by a worker shutdown" do
      expect do
        LlmCostTracker.track_stream(provider: :openai, model: "gpt-4o") do |stream|
          stream.usage(input_tokens: 100, output_tokens: 20)
          raise shutdown
        end
      end.to raise_error(shutdown)
      expect(LlmCostTracker::Call.count).to eq(1)
    end
  end

  describe "LlmCostTracker.track" do
    it "records the call before raising UnknownPricingError" do
      LlmCostTracker.configure { |c| c.pricing.unknown_model_behavior = :raise }

      expect do
        LlmCostTracker.track(provider: :openai, model: unpriced_model, tokens: { input_tokens: 100, output_tokens: 20 })
      end.to raise_error(LlmCostTracker::UnknownPricingError)
      expect(LlmCostTracker::Call.sole).to have_attributes(model: unpriced_model, cost_status: "unknown")
    end

    it "still raises when the async inbox cannot lend a connection" do
      LlmCostTracker.configure { |c| c.ingestion.mode = :async }
      allow(LlmCostTracker::Ingestion::Pool).to receive(:with_connection).and_raise(ActiveRecord::ConnectionTimeoutError)

      expect do
        LlmCostTracker.track(provider: :openai, model: "gpt-4o", tokens: { input_tokens: 1, output_tokens: 1 })
      end.to raise_error(LlmCostTracker::Error, /could not checkout/)
    end
  end

  describe "LlmCostTracker.track_stream" do
    it "records the stream before raising UnknownPricingError" do
      LlmCostTracker.configure { |c| c.pricing.unknown_model_behavior = :raise }

      expect do
        LlmCostTracker.track_stream(provider: :openai, model: unpriced_model) do |stream|
          stream.usage(input_tokens: 100, output_tokens: 20)
        end
      end.to raise_error(LlmCostTracker::UnknownPricingError)
      expect(LlmCostTracker::Call.sole).to have_attributes(model: unpriced_model, stream: true)
    end

    it "does not replace the block's exception with a recording error" do
      LlmCostTracker.configure { |c| c.pricing.unknown_model_behavior = :raise }
      allow(LlmCostTracker::Logging).to receive(:warn)

      expect do
        LlmCostTracker.track_stream(provider: :openai, model: unpriced_model) do |stream|
          stream.usage(input_tokens: 100, output_tokens: 20)
          raise host_error, "client failed"
        end
      end.to raise_error(host_error, "client failed")
      expect(LlmCostTracker::Call.sole).to have_attributes(model: unpriced_model, stream: true)
      expect(LlmCostTracker::Logging).to have_received(:warn)
        .with(/track_stream recorded the errored stream and did not raise LlmCostTracker::UnknownPricingError/)
    end
  end

  describe "configuration" do
    it "rejects a malformed pricing.file at configure time" do
      Tempfile.create(["llm-prices", ".yml"]) do |file|
        file.write("models: [unclosed\n")
        file.close

        expect do
          LlmCostTracker.configure { |c| c.pricing.file = file.path }
        end.to raise_error(LlmCostTracker::Error, /Unable to load prices_file.*prices:refresh/m)
      end
    end

    {
      "service charges" => { "models" => {}, "service_charges" => { "openai" => { "not_a_dimension" => 1 } } },
      "metadata" => { "models" => {}, "metadata" => "not a hash" }
    }.each do |section, registry|
      it "rejects a pricing.file with invalid #{section} at configure time" do
        Tempfile.create(["llm-prices", ".yml"]) do |file|
          file.write(registry.to_yaml)
          file.close

          expect { LlmCostTracker.configure { |c| c.pricing.file = file.path } }
            .to raise_error(LlmCostTracker::Error, /prices:refresh/)
        end
      end
    end

    it "warns at configure time when pricing.file does not exist" do
      log = capture_log do
        LlmCostTracker.configure { |c| c.pricing.file = "/nonexistent/llm_cost_tracker_prices.yml" }
      end

      expect(log).to include("/nonexistent/llm_cost_tracker_prices.yml").and include("prices:refresh")
    end

    it "reports a missing pricing.file as a doctor error" do
      LlmCostTracker.configure { |c| c.pricing.file = "/nonexistent/llm_cost_tracker_prices.yml" }

      check = LlmCostTracker::Doctor::PriceCheck.new.call

      expect(check.status).to eq(:error)
      expect(check.message).to include("does not exist")
    end
  end
end
