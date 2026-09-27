# frozen_string_literal: true

require "spec_helper"
require "bigdecimal"
require "faraday"

RSpec.describe "Gemini billing" do
  let(:host) { "https://generativelanguage.googleapis.com" }
  let(:events) { [] }

  before do |example|
    allow(LlmCostTracker::Ingestion::Inbox).to receive(:save).and_return(true)
    allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_return(true)
    ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) { |*, payload| events << payload }
    LlmCostTracker.configure do |config|
      config.pricing.overrides = {
        "gemini/gemini-2.5-flash" => { "input" => 0.30, "output" => 2.50, "grounding_request" => 35.0,
                                       "maps_grounding_request" => 25.0 },
        "gemini/gemini-2.5-pro" => { "input" => 1.25, "output" => 10.0, "cache_storage_token_hour" => 4.50 },
        "gemini/gemini-3-flash-preview" => { "input" => 0.50, "output" => 3.00 },
        "gemini/gemini-3.1-flash-image" => { "input" => 0.50, "output" => 3.00, "image_output" => 60.0,
                                             "grounding_request" => 14.0 },
        "gemini/gemini-3.8-flash" => { "input" => 0.75, "output" => 3.75, "grounding_request" => 14.0,
                                       "maps_grounding_request" => 14.0,
                                       "input_from_2027-01-01" => 1.50, "output_from_2027-01-01" => 7.50 }
      }
      if example.metadata[:compat_host]
        config.capture.openai_compatible_providers["generativelanguage.googleapis.com"] = "gemini"
      end
      if example.metadata[:budget_spent]
        config.budgets.daily = 10.0
        config.budgets.exceeded_behavior = :block_requests
      end
    end
  end

  def tokens(count, rate) = BigDecimal(count.to_s) * BigDecimal(rate.to_s) / 1_000_000

  def per_1k(count, rate) = BigDecimal(count.to_s) * BigDecimal(rate.to_s) / 1_000

  def call(verb, path, response, request: {}, stream: false)
    body = stream ? response.map { |data| "data: #{data.to_json}\n\n" }.join : response.to_json
    Faraday.new(url: host) do |f|
      f.use :llm_cost_tracker
      f.adapter(:test) do |stub|
        stub.public_send(verb, path) do |env|
          env.request.on_data&.call(body, body.bytesize, env)
          [200, { "Content-Type" => stream ? "text/event-stream" : "application/json" }, stream ? "" : body]
        end
      end
    end.public_send(verb, path, (request.to_json unless request.empty?)) do |req|
      req.options.on_data = proc {} if stream
    end
  end

  def total = BigDecimal(events.last.dig(:cost, :total).to_s)

  def generate(model, response)
    call(:post, "/v1beta/models/#{model}:generateContent", response, request: { contents: [] })
  end

  it "records an Interactions API call" do
    call(:post, "/v1beta/interactions",
         { id: "v1_int", model: "gemini-3.8-flash", status: "completed",
           usage: { total_input_tokens: 27, total_output_tokens: 45, total_thought_tokens: 31, total_tokens: 103,
                    grounding_tool_count: [{ type: "google_search", count: 2 }] } },
         request: { model: "gemini-3.8-flash", input: "Who won the euro 2024?", tools: [{ type: "google_search" }] })

    expect(events.last).to include(model: "gemini-3.8-flash", provider_response_id: "v1_int", cost_status: "complete")
    expect(total).to eq(tokens(27, "0.75") + tokens(45 + 31, "3.75") + per_1k(2, 14))
  end

  it "records an Interactions API stream that ends before interaction.completed under the requested model" do
    call(:post, "/v1beta/interactions",
         [{ event_type: "interaction.created", interaction: { id: "v1_cut", status: "in_progress" } }],
         request: { model: "gemini-3-flash-preview", input: "Count to 50", stream: true }, stream: true)

    expect(events.last).to include(model: "gemini-3-flash-preview", usage_source: "unknown", stream: true)
  end

  it "records a streamed Interactions API call from its interaction.completed event" do
    call(:post, "/v1beta/interactions",
         [{ event_type: "interaction.created",
            interaction: { id: "v1_s", status: "in_progress", model: "gemini-3-flash-preview" } },
          { event_type: "step.delta", index: 1, delta: { text: "1, 2, 3", type: "text" } },
          { event_type: "interaction.completed",
            interaction: { id: "v1_s", status: "completed", model: "gemini-3-flash-preview", service_tier: "standard",
                           usage: { total_tokens: 346, total_input_tokens: 11, total_cached_tokens: 0,
                                    input_tokens_by_modality: [{ modality: "text", tokens: 11 }],
                                    total_output_tokens: 90, total_tool_use_tokens: 0, total_thought_tokens: 245 } } }],
         request: { model: "gemini-3-flash-preview", input: "Count to 50", stream: true }, stream: true)

    expect(events.last).to include(stream: true, usage_source: "stream_final", model: "gemini-3-flash-preview")
    expect(total).to eq(tokens(11, "0.50") + tokens(90 + 245, "3.00"))
  end

  it "prices a -latest alias as the model version that served it, grounding per query" do
    generate("gemini-flash-latest",
             modelVersion: "gemini-3.8-flash",
             candidates: [{ groundingMetadata: { webSearchQueries: %w[q1 q2 q3] } }],
             usageMetadata: { promptTokenCount: 1_000, candidatesTokenCount: 500, totalTokenCount: 1_500 })

    expect(events.last).to include(model: "gemini-3.8-flash", cost_status: "complete")
    expect(total).to eq(tokens(1_000, "0.75") + tokens(500, "3.75") + per_1k(3, 14))
  end

  it "takes a track_stream model from modelVersion when none is given" do
    LlmCostTracker.track_stream(provider: :gemini) do |stream|
      stream.event({ "modelVersion" => "gemini-3.8-flash",
                     "usageMetadata" => { "promptTokenCount" => 1_000, "candidatesTokenCount" => 500 } })
    end

    expect(events.last[:model]).to eq("gemini-3.8-flash")
    expect(total).to eq(tokens(1_000, "0.75") + tokens(500, "3.75"))
  end

  it "counts image search queries as grounding on image models" do
    generate("gemini-3.1-flash-image",
             modelVersion: "gemini-3.1-flash-image",
             candidates: [{ groundingMetadata: { webSearchQueries: ["resplendent quetzal"],
                                                 imageSearchQueries: ["resplendent quetzal photo"] } }],
             usageMetadata: { promptTokenCount: 20, candidatesTokenCount: 1_220, totalTokenCount: 1_240,
                              candidatesTokensDetails: [{ modality: "TEXT", tokenCount: 100 },
                                                        { modality: "IMAGE", tokenCount: 1_120 }] })

    expect(events.last[:cost_status]).to eq("complete")
    expect(total).to eq(tokens(20, "0.50") + tokens(100, "3.00") + tokens(1_120, "60.00") + per_1k(2, 14))
  end

  it "prices Google Maps grounding at the Maps rate, per prompt on 2.5 and per query on 3.x" do
    maps_chunk = { maps: { uri: "https://maps.google.com/?cid=1", title: "Cafe", placeId: "places/1" } }
    usage = { promptTokenCount: 100, candidatesTokenCount: 300, totalTokenCount: 400 }
    generate("gemini-2.5-flash", candidates: [{ groundingMetadata: { groundingChunks: [maps_chunk] } }],
                                 usageMetadata: usage)
    generate("gemini-3.8-flash", candidates: [{ groundingMetadata: { groundingChunks: [maps_chunk],
                                                                     webSearchQueries: %w[cafes parks] } }],
                                 usageMetadata: usage)

    flash25, flash38 = events.map { |event| BigDecimal(event.dig(:cost, :total).to_s) }
    expect(events.map { |event| event[:line_items].last[:kind] }).to all(eq("maps_grounding_request"))
    expect(flash25).to eq(tokens(100, "0.30") + tokens(300, "2.50") + per_1k(1, 25))
    expect(flash38).to eq(tokens(100, "0.75") + tokens(300, "3.75") + per_1k(2, 14))
  end

  it "prices a call by the rate in effect on its date" do
    usage = { usageMetadata: { promptTokenCount: 1_000, candidatesTokenCount: 500, totalTokenCount: 1_500 } }
    travel_to(Time.utc(2026, 12, 31, 23, 59)) { generate("gemini-3.8-flash", usage) }
    travel_to(Time.utc(2027, 1, 2)) { generate("gemini-3.8-flash", usage) }

    expect(events.map { |event| BigDecimal(event.dig(:cost, :total).to_s) })
      .to eq([tokens(1_000, "0.75") + tokens(500, "3.75"), tokens(1_000, "1.50") + tokens(500, "7.50")])
  end

  it "estimates explicit cache storage from the TTL a create sets" do
    cache = { name: "cachedContents/abc", model: "models/gemini-2.5-pro", createTime: "2026-09-26T10:00:00Z",
              updateTime: "2026-09-26T10:00:00Z", expireTime: "2026-09-26T18:00:00Z",
              usageMetadata: { totalTokenCount: 500_000 } }
    call(:post, "/v1beta/cachedContents", cache, request: { model: "models/gemini-2.5-pro", contents: [], ttl: "28800s" })
    call(:get, "/v1beta/cachedContents", { cachedContents: [cache] })

    expect(events.size).to eq(1)
    expect(events.last).to include(model: "gemini-2.5-pro", provider_response_id: "cachedContents/abc",
                                   cost_status: "complete")
    expect(total).to eq(tokens(500_000 * 8, "4.50"))
  end

  it "does not hold back reading, updating or deleting a context cache or an interaction when a blocking budget is spent",
     :budget_spent do
    allow(LlmCostTracker::Ledger::Period::Totals).to receive(:call).and_return(day: 12.0)

    expect do
      call(:get, "/v1beta/cachedContents/abc", {})
      call(:patch, "/v1beta/cachedContents/abc", {}, request: { ttl: "3600s" })
      call(:delete, "/v1beta/cachedContents/abc", {})
      call(:get, "/v1beta/interactions/v1_bg", { id: "v1_bg", status: "in_progress" })
      call(:delete, "/v1beta/interactions/v1_bg", {})
    end.not_to raise_error
    expect(events).to be_empty
  end

  it "parses native Gemini chunks in track_stream when the host is also an OpenAI-compatible provider",
     :compat_host do
    LlmCostTracker.track_stream(provider: :gemini, model: "gemini-2.5-flash") do |stream|
      stream.event({ "usageMetadata" => { "promptTokenCount" => 1_000, "candidatesTokenCount" => 300,
                                          "thoughtsTokenCount" => 200 } })
    end
    LlmCostTracker.track_stream(provider: :gemini, model: "gemini-2.5-flash") do |stream|
      stream.event({ "object" => "chat.completion.chunk", "model" => "gemini-2.5-flash", "choices" => [],
                     "usage" => { "prompt_tokens" => 1_000, "completion_tokens" => 500, "total_tokens" => 1_500 } })
    end

    expect(events.map { |event| BigDecimal(event.dig(:cost, :total).to_s) })
      .to all(eq(tokens(1_000, "0.30") + tokens(500, "2.50")))
  end
end
