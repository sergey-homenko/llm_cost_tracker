# frozen_string_literal: true

require "spec_helper"
require "weakref"
require "openai"
require "llm_cost_tracker/capture/stream_collector"
require "llm_cost_tracker/capture/stream_tracker"

RSpec.describe LlmCostTracker::Capture::StreamTracker do
  let(:stream_class) do
    Class.new do
      def each
        yield({ "type" => "chunk" })
      end
    end
  end

  def consumed_stream_ref(collector)
    stream = described_class.new(stream: stream_class.new, collector: collector, active: -> { true }).wrap
    stream.each { |_| nil }
    WeakRef.new(stream)
  end

  it "lets a consumed stream be garbage-collected once the caller drops it" do
    collector = instance_double(LlmCostTracker::Capture::StreamCollector, event: nil, finish!: nil)
    refs = Array.new(20) { consumed_stream_ref(collector) }
    3.times { GC.start(full_mark: true, immediate_sweep: true) }

    expect(refs.count(&:weakref_alive?)).to be < 5
    expect(collector).to have_received(:finish!).with(errored: false).exactly(20).times
  end

  it "closes the SDK's own iterator and finishes once when the caller closes a wrapped stream" do
    closed = []
    sdk_stream = Class.new do
      include OpenAI::Internal::Type::BaseStream

      def initialize(iterator) = @iterator = iterator
    end
    iterator = OpenAI::Internal::Util.fused_enum(Enumerator.new { |y| y << { "id" => "c1" } }) { closed << :closed }
    collector = instance_double(LlmCostTracker::Capture::StreamCollector, event: nil, finish!: nil)
    stream = described_class.new(stream: sdk_stream.new(iterator), collector: collector, active: -> { true }).wrap

    stream.close

    expect(closed).to eq([:closed])
    expect(collector).to have_received(:finish!).with(errored: false).once
  end

  it "finishes again on the next iteration when the previous finish raised" do
    attempts = 0
    finish = lambda do |_errored|
      attempts += 1
      raise StandardError, "database is down" if attempts == 1
    end
    collector = instance_double(LlmCostTracker::Capture::StreamCollector, event: nil)
    stream = described_class.new(stream: stream_class.new, collector: collector,
                                 active: -> { true }, finish: finish).wrap

    expect { stream.each { |_| nil } }.to raise_error(StandardError, "database is down")
    2.times { stream.each { |_| nil } }

    expect(attempts).to eq(2)
  end

  it "keeps relaying events and warns once when the collector cannot capture them" do
    collector = instance_double(LlmCostTracker::Capture::StreamCollector, finish!: nil)
    allow(collector).to receive(:event).and_raise(StandardError, "collector is broken")
    allow(LlmCostTracker::Logging).to receive(:warn)
    two_events = Class.new do
      def each
        yield({ "type" => "chunk" })
        yield({ "type" => "done" })
      end
    end
    stream = described_class.new(stream: two_events.new, collector: collector, active: -> { true }).wrap

    relayed = []
    stream.each { |event| relayed << event }

    expect(relayed).to eq([{ "type" => "chunk" }, { "type" => "done" }])
    expect(LlmCostTracker::Logging).to have_received(:warn)
      .with("stream integration failed to capture event: StandardError: collector is broken").once
  end

  it "finishes the collector once even when the stream is iterated twice" do
    collector = instance_double(LlmCostTracker::Capture::StreamCollector, event: nil, finish!: nil)
    stream = described_class.new(stream: stream_class.new, collector: collector, active: -> { true }).wrap

    2.times { stream.each { |_| nil } }

    expect(collector).to have_received(:event).twice
    expect(collector).to have_received(:finish!).once
  end
end
