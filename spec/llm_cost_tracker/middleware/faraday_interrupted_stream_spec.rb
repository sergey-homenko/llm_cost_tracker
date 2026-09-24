# frozen_string_literal: true

require "spec_helper"
require "faraday"

RSpec.describe LlmCostTracker::Middleware::Faraday do
  before do
    allow(LlmCostTracker::Ingestion::Inbox).to receive(:save).and_return(true)
    allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_return(true)
  end

  let(:gemini_key) { "AIzaSy#{'A1b2C3d4' * 4}x" }
  let(:events) { [] }

  before do
    ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) { |*, payload| events << payload }
  end

  def gemini_connection(status)
    Faraday.new(url: "https://generativelanguage.googleapis.com") do |f|
      f.use :llm_cost_tracker
      f.request :json
      f.response :raise_error
      f.adapter :test do |stub|
        stub.post(%r{/v1beta/models/gemini-2\.5-flash:streamGenerateContent}) { [status, {}, "{}"] }
      end
    end
  end

  [429, 503].each do |status|
    it "keeps the ?key= query param out of the tags when raise_error inside the tracker raises on a streamed #{status}" do
      conn = gemini_connection(status)

      expect do
        conn.post("/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse&key=#{gemini_key}",
                  { contents: [] }) { |req| req.options.on_data = proc {} }
      end.to raise_error(Faraday::Error, /#{gemini_key}/) # premise: Faraday puts the full URL in its message

      expect(events.size).to eq(1)
      expect(events.first[:tags].to_json).not_to include(gemini_key)
      expect(events.first[:tags]).to include(
        stream_interrupted: true,
        stream_interrupted_error: status == 429 ? "Faraday::TooManyRequestsError" : "Faraday::ServerError",
        stream_interrupted_status: status
      )
    end
  end

  it "keeps the key out of a tag built from the request URL by a tags callable" do
    conn = Faraday.new(url: "https://generativelanguage.googleapis.com") do |f|
      f.use :llm_cost_tracker, tags: ->(env) { { endpoint: env.url } }
      f.request :json
      f.adapter :test do |stub|
        stub.post(%r{/v1beta/models/gemini-2\.5-flash:generateContent}) do
          [200, { "Content-Type" => "application/json" },
           { usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5, totalTokenCount: 15 } }.to_json]
        end
      end
    end

    conn.post("/v1beta/models/gemini-2.5-flash:generateContent?key=#{gemini_key}", { contents: [] })

    expect(events.first[:tags][:endpoint].to_s).to include("generativelanguage.googleapis.com")
    expect(events.first[:tags].to_json).not_to include(gemini_key)
  end

  it "records only the error class for a transport failure with no HTTP status" do
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter :test do |stub|
        stub.post("/v1/chat/completions") { |_env| raise Faraday::ConnectionFailed, "network died mid-stream" }
      end
    end

    expect do
      conn.post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json) do |req|
        req.options.on_data = proc {}
      end
    end.to raise_error(Faraday::ConnectionFailed)

    expect(events.first[:tags][:stream_interrupted_error]).to eq("Faraday::ConnectionFailed")
    expect(events.first[:tags]).not_to have_key(:stream_interrupted_status)
  end

  it "records only the error class when the stream is cut by an error that is not a Faraday error" do
    conn = Faraday.new(url: "https://api.openai.com") do |f|
      f.use :llm_cost_tracker
      f.adapter(:test) { |stub| stub.post("/v1/chat/completions") { raise IOError, "stream closed" } }
    end

    expect do
      conn.post("/v1/chat/completions", { model: "gpt-4o", stream: true }.to_json) do |req|
        req.options.on_data = proc {}
      end
    end.to raise_error(IOError)

    expect(events.first[:tags]).to include(stream_interrupted_error: "IOError")
    expect(events.first[:tags]).not_to have_key(:stream_interrupted_status)
  end

  it "records the Gemini model from the URL on an interrupted stream instead of unknown" do
    conn = gemini_connection(429)

    expect do
      conn.post("/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse", { contents: [] }) do |req|
        req.options.on_data = proc {}
      end
    end.to raise_error(Faraday::TooManyRequestsError)

    expect(events.first[:model]).to eq("gemini-2.5-flash")
  end
end
