# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/capture/event_window"

RSpec.describe LlmCostTracker::Capture::EventWindow do
  let(:head) { described_class::HEAD_EVENTS }
  let(:tail) { described_class::TAIL_EVENTS }

  def push_numbered(window, count, &)
    count.times { |index| window.push({ "n" => index }.merge(block_given? ? yield(index) : {}), type: "chunk") }
  end

  it "keeps the first and the last events in stream order and drops the middle within its byte limit" do
    stub_const("LlmCostTracker::Capture::SSE::LIMIT_BYTES", 64 * 1024)
    window = described_class.new
    push_numbered(window, 10_000)

    numbers = window.events.map { |event| event[:data]["n"] }
    expect(numbers).to eq((0...head).to_a + ((10_000 - tail)...10_000).to_a)
    expect(window.events.first[:event]).to eq("chunk")
    expect(window).not_to be_overflowed
  end

  it "keeps the middle events the notable predicate asks for, in stream order" do
    window = described_class.new(notable: ->(data) { data["tool"] == true })
    push_numbered(window, 5_000) { |index| [700, 2_500].include?(index) ? { "tool" => true } : {} }

    numbers = window.events.map { |event| event[:data]["n"] }
    expect(numbers).to eq((0...head).to_a + [700, 2_500] + ((5_000 - tail)...5_000).to_a)
  end

  it "overflows and releases everything once the retained events outgrow the byte limit" do
    window = described_class.new
    stub_const("LlmCostTracker::Capture::SSE::LIMIT_BYTES", 100)
    push_numbered(window, 20) { { "delta" => "x" * 20 } }

    expect(window).to be_overflowed
    expect(window.events).to be_empty
  end

  it "treats a raising notable predicate as not notable" do
    window = described_class.new(notable: ->(_data) { raise "boom" })
    push_numbered(window, head + tail + 5)

    expect(window.events.size).to eq(head + tail)
  end
end
