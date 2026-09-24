# frozen_string_literal: true

require "spec_helper"
require "active_record"

RSpec.describe LlmCostTracker::Ledger::Storable do
  before do
    establish_database_connection!
    create_lct_tables!
    [LlmCostTracker::Call, LlmCostTracker::CallLineItem, LlmCostTracker::CallTag,
     LlmCostTracker::CallRollup].each(&:reset_column_information)
  end

  after { disconnect_database! }

  def track(**overrides)
    LlmCostTracker.track(provider: :openai, model: "gpt-4o",
                         tokens: { input_tokens: 1_000_000, output_tokens: 0 }, **overrides)
  end

  describe "inline writes" do
    it "stores a call whose strings carry NUL bytes or invalid UTF-8" do
      event = track(
        model: "gpt-4o\u0000",
        provider_response_id: "resp\u0000_1",
        tags: { query: "abc\u0000def", note: "caf\xE9".dup.force_encoding("UTF-8"), nested: { q: "x\u0000y" } },
        service_line_items: [{ dimension_key: "web_search_request", quantity: 1,
                               provider_item_id: "ws\u0000_1", details: { "no\u0000te" => "x\u0000y" } }]
      )

      call = LlmCostTracker::Call.find_by!(event_id: event.event_id)
      expect(call.model).to eq("gpt-4o")
      expect(call.provider_response_id).to eq("resp_1")
      expect(call.tag_pairs).to include("query" => "abcdef", "note" => "caf�")
      item = LlmCostTracker::CallLineItem.find_by!(llm_cost_tracker_call_id: call.id, provider_item_id: "ws_1")
      expect(item.details).to eq("note" => "xy")
    end

    it "stores a call whose token counts overflow the integer columns and keeps its cost" do
      allow(LlmCostTracker::Logging).to receive(:warn)
      event = track(tokens: { input_tokens: 1_500_000_000, output_tokens: 1_000_000_000 })

      call = LlmCostTracker::Call.find_by!(event_id: event.event_id)
      expect(call.total_tokens).to eq((2**31) - 1)
      expect(call.total_cost).to eq(event.total_cost)
      expect(LlmCostTracker::Logging).to have_received(:warn).with(include("token"))
    end

    it "stores a call whose model or response id carries invalid UTF-8 or an inner NUL" do
      event = track(model: "gpt\u0000-4o-caf\xE9".dup.force_encoding("UTF-8"),
                    provider_response_id: "resp-\xE9".dup.force_encoding("UTF-8"), pricing_mode: "fl\u0000ex")

      call = LlmCostTracker::Call.find_by!(event_id: event.event_id)
      expect(call).to have_attributes(model: "gpt-4o-caf\uFFFD", provider_response_id: "resp-\uFFFD",
                                      pricing_mode: "flex")
    end

    it "prices a long model by its full name and matches a long response id when deduplicating" do
      model = "ft:gpt-4o:#{'m' * 300}"
      LlmCostTrackerReset.call
      LlmCostTracker.configure { |c| c.pricing.overrides = { model => { input: 1.0, output: 2.0 } } }

      event = track(model: model, provider_response_id: "r" * 300)

      expect(LlmCostTracker::Call.find_by!(event_id: event.event_id).total_cost.to_d).to eq(BigDecimal("1.0"))
      expect(LlmCostTracker::Call.already_recorded?(provider: "openai", provider_response_id: "r" * 300)).to be(true)
    end

    it "caps identifier strings at the 255 characters a MySQL string column holds" do
      event = track(model: "m" * 300)

      expect(LlmCostTracker::Call.find_by!(event_id: event.event_id).model.length).to eq(255)
    end
  end

  describe "text and json cleaning" do
    it "reads valid UTF-8 carried in a binary string and converts other encodings" do
      expect(described_class.text("café".b)).to eq("café")
      expect(described_class.text("caf\xE9".dup.force_encoding("ISO-8859-1"))).to eq("café")
      expect(described_class.text("café".encode("UTF-16LE"))).to eq("café")
    end

    it "cleans Symbol keys and values and keeps clean Symbols as they are" do
      expect(described_class.json({ "no\u0000te": :"a\u0000b", ok: :fine })).to eq(note: :ab, ok: :fine)
    end

    it "cleans the provider, usage source and pricing mode of an event" do
      event = LlmCostTracker::Event.build(
        provider: "open\u0000ai", model: "gpt-4o", usage_source: "resp\u0000onse", pricing_mode: "fl\u0000ex",
        token_usage: LlmCostTracker::Usage::TokenUsage.build(input_tokens: 1, output_tokens: 1)
      )

      expect(described_class.event(event)).to have_attributes(provider: "openai", usage_source: "response",
                                                               pricing_mode: "flex")
    end
  end

  describe "tag sanitizer" do
    it "does not raise on long invalid UTF-8 while scanning for secrets" do
      bad = ("\xFF\xFE" * 10).dup.force_encoding("UTF-8")

      expect(LlmCostTracker::Tags::Sanitizer.call({ q: bad })).to eq(q: "�" * 20)
      expect { LlmCostTracker.with_tags(q: bad) { :ran } }.not_to raise_error
    end

    it "strips NUL bytes from scalar and nested values" do
      expect(LlmCostTracker::Tags::Sanitizer.call({ q: "a\u0000b", h: { k: ["x\u0000"] } }))
        .to eq(q: "ab", h: { k: ["x"] })
    end
  end
end
