# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/capture/stream_tap"

RSpec.describe LlmCostTracker::Capture::StreamTap do
  it "decodes events split across chunk boundaries into the window" do
    tap = described_class.new
    expect(tap).not_to be_received
    body = "data: {\"id\":\"chatcmpl_a\"}\n\ndata: {\"usage\":{\"prompt_tokens\":1}}\n\ndata: [DONE]\n\n"
    body.each_char.each_slice(3) { |slice| tap << slice.join }

    expect(tap).to be_received
    expect(tap.events.map { |event| event[:data] }).to eq([{ "id" => "chatcmpl_a" },
                                                          { "usage" => { "prompt_tokens" => 1 } }])
  end

  it "stops capturing once a single unterminated event outgrows the pending limit" do
    stub_const("LlmCostTracker::Capture::StreamTap::MAX_PENDING_BYTES", 64)
    tap = described_class.new
    tap << "data: {\"id\":\"chatcmpl_a\"}\n\n"
    tap << "data: #{'x' * 100}"

    expect(tap).to be_failed
    expect(tap.events).to be_empty
  end
end
