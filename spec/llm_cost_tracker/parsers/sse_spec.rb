# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Parsers::SSE do
  describe ".parse" do
    it "returns an empty array for nil or empty input" do
      expect(described_class.parse(nil)).to eq([])
      expect(described_class.parse("")).to eq([])
    end

    it "parses SSE events with data-only lines" do
      body = "data: {\"id\":\"1\"}\n\ndata: {\"id\":\"2\"}\n\n"

      events = described_class.parse(body)

      expect(events).to eq([
        { event: nil, data: { "id" => "1" } },
        { event: nil, data: { "id" => "2" } }
      ])
    end

    it "parses named SSE events alongside their data payload" do
      body = <<~SSE
        event: message_start
        data: {"type":"message_start"}

        event: message_delta
        data: {"type":"message_delta"}

      SSE

      events = described_class.parse(body)

      expect(events).to eq([
        { event: "message_start", data: { "type" => "message_start" } },
        { event: "message_delta", data: { "type" => "message_delta" } }
      ])
    end

    it "drops the [DONE] sentinel" do
      body = "data: {\"id\":\"1\"}\n\ndata: [DONE]\n\n"

      events = described_class.parse(body)

      expect(events.size).to eq(1)
      expect(events.first[:data]).to eq("id" => "1")
    end

    it "ignores comment lines starting with a colon" do
      body = ": heartbeat\n\ndata: {\"id\":\"1\"}\n\n"

      events = described_class.parse(body)

      expect(events.size).to eq(1)
    end

    it "joins multi-line data payloads with newlines before decoding" do
      body = "data: line-one\ndata: line-two\n\n"

      events = described_class.parse(body)

      expect(events.first[:data]).to eq("line-one\nline-two")
    end

    it "keeps raw payload strings when they are not valid JSON" do
      body = "data: not-json\n\n"

      events = described_class.parse(body)

      expect(events.first[:data]).to eq("not-json")
    end

    it "parses Gemini-style JSON array bodies into events" do
      body = JSON.dump([{ "usageMetadata" => { "promptTokenCount" => 10 } }])

      events = described_class.parse(body)

      expect(events.size).to eq(1)
      expect(events.first[:event]).to be_nil
      expect(events.first[:data]).to eq("usageMetadata" => { "promptTokenCount" => 10 })
    end

    it "returns an empty array when the JSON array body is malformed" do
      expect(described_class.parse("[not json")).to eq([])
    end
  end
end
