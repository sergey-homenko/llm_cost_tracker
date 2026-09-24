# frozen_string_literal: true

require "spec_helper"
require "weakref"
require "llm_cost_tracker/capture/stream_collector"
require "llm_cost_tracker/capture/stream_tracker"

RSpec.describe LlmCostTracker::Capture::StreamTracker do
  let(:each_stream_class) do
    Class.new do
      def each
        yield({ "type" => "chunk" })
      end
    end
  end

  let(:iterator_stream_class) do
    Class.new do
      def initialize
        @iterator = [{ "type" => "chunk" }].each
      end

      def each(&)
        @iterator.each(&)
      end
    end
  end

  def consumed_stream_ref(stream_class, collector)
    stream = described_class.new(stream: stream_class.new, collector: collector, active: -> { true }).wrap
    stream.each { |_| nil }
    WeakRef.new(stream)
  end

  def live_count(refs)
    3.times { GC.start(full_mark: true, immediate_sweep: true) }
    refs.count(&:weakref_alive?)
  end

  it "logs a failure to record an errored stream and keeps the caller's exception" do
    host_error = Class.new(StandardError)
    finish = ->(_errored) { raise ArgumentError, "finish failed" }
    stream = described_class.new(stream: each_stream_class.new, collector: instance_double(
      LlmCostTracker::Capture::StreamCollector, event: nil
    ), active: -> { true }, finish: finish).wrap
    allow(LlmCostTracker::Logging).to receive(:warn)

    expect { stream.each { raise host_error, "render failed" } }.to raise_error(host_error, "render failed")
    expect(LlmCostTracker::Logging).to have_received(:warn)
      .with(/could not record an errored stream: ArgumentError: finish failed/)
  end

  it "lets a stream wrapped through #each be garbage-collected once the caller drops it" do
    collector = instance_double(LlmCostTracker::Capture::StreamCollector, event: nil, finish!: nil)
    refs = Array.new(20) { consumed_stream_ref(each_stream_class, collector) }

    expect(live_count(refs)).to be < 5
    expect(collector).to have_received(:finish!).with(errored: false).exactly(20).times
  end

  it "lets a stream wrapped through its @iterator be garbage-collected once the caller drops it" do
    collector = instance_double(LlmCostTracker::Capture::StreamCollector, event: nil, finish!: nil)
    refs = Array.new(20) { consumed_stream_ref(iterator_stream_class, collector) }

    expect(live_count(refs)).to be < 5
    expect(collector).to have_received(:finish!).with(errored: false).exactly(20).times
  end

  it "finishes again on the next iteration when the previous finish raised" do
    attempts = 0
    finish = lambda do |_errored|
      attempts += 1
      raise StandardError, "database is down" if attempts == 1
    end
    collector = instance_double(LlmCostTracker::Capture::StreamCollector, event: nil)
    stream = described_class.new(stream: each_stream_class.new, collector: collector,
                                 active: -> { true }, finish: finish).wrap

    expect { stream.each { |_| nil } }.to raise_error(StandardError, "database is down")
    2.times { stream.each { |_| nil } }

    expect(attempts).to eq(2)
  end

  it "finishes the collector once even when the stream is iterated twice" do
    collector = instance_double(LlmCostTracker::Capture::StreamCollector, event: nil, finish!: nil)
    stream = described_class.new(stream: each_stream_class.new, collector: collector, active: -> { true }).wrap

    2.times { stream.each { |_| nil } }

    expect(collector).to have_received(:event).twice
    expect(collector).to have_received(:finish!).once
  end
end
