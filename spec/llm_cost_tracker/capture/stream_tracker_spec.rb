# frozen_string_literal: true

require "spec_helper"
require "weakref"
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

  it "finishes the collector once even when the stream is iterated twice" do
    collector = instance_double(LlmCostTracker::Capture::StreamCollector, event: nil, finish!: nil)
    stream = described_class.new(stream: stream_class.new, collector: collector, active: -> { true }).wrap

    2.times { stream.each { |_| nil } }

    expect(collector).to have_received(:event).twice
    expect(collector).to have_received(:finish!).once
  end
end
