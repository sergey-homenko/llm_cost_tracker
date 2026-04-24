# frozen_string_literal: true

require "monitor"

require_relative "value_helpers"

module LlmCostTracker
  class StreamCollector
    attr_reader :provider

    def initialize(provider:, model:, latency_ms: nil, provider_response_id: nil, metadata: {})
      @provider = provider.to_s
      @model = model
      @latency_ms = latency_ms
      @provider_response_id = provider_response_id
      @metadata = ValueHelpers.deep_dup(metadata || {})
      @events = []
      @explicit_usage = nil
      @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @finished = false
      @monitor = Monitor.new
    end

    def model = @monitor.synchronize { @model }

    def metadata = @monitor.synchronize { ValueHelpers.deep_dup(@metadata) }

    def provider_response_id = @monitor.synchronize { @provider_response_id }

    def model=(value)
      @monitor.synchronize do
        ensure_open!
        @model = value
      end
    end

    def provider_response_id=(value)
      @monitor.synchronize do
        ensure_open!
        @provider_response_id = value
      end
    end

    def event(data, type: nil)
      @monitor.synchronize do
        ensure_open!
        @events << { event: type, data: ValueHelpers.deep_dup(data) } unless data.nil?
      end
      self
    end
    alias chunk event

    def usage(input_tokens:, output_tokens:, **extra)
      @monitor.synchronize do
        ensure_open!
        @explicit_usage = ValueHelpers.deep_dup(
          extra.merge(
            input_tokens: input_tokens.to_i,
            output_tokens: output_tokens.to_i
          )
        )
      end
      self
    end

    def finish!(errored: false)
      snapshot = @monitor.synchronize do
        return if @finished

        @finished = true
        {
          events: @events.dup,
          explicit_usage: ValueHelpers.deep_dup(@explicit_usage),
          model: @model,
          latency_ms: @latency_ms,
          provider_response_id: @provider_response_id,
          metadata: ValueHelpers.deep_dup(@metadata)
        }
      end

      parsed = build_parsed_usage(snapshot)
      Tracker.record(
        provider: parsed.provider,
        model: parsed.model,
        input_tokens: parsed.input_tokens,
        output_tokens: parsed.output_tokens,
        latency_ms: snapshot[:latency_ms] || elapsed_ms,
        stream: true,
        usage_source: parsed.usage_source,
        provider_response_id: parsed.provider_response_id || snapshot[:provider_response_id],
        metadata: error_metadata(errored).merge(snapshot[:metadata]).merge(parsed.metadata)
      )
    end

    private

    def ensure_open!
      return unless @finished

      raise FrozenError, "can't modify finished LlmCostTracker::StreamCollector"
    end

    def build_parsed_usage(snapshot)
      return build_from_explicit_usage(snapshot) if snapshot[:explicit_usage]

      parsed = Parsers::Registry.find_for_provider(@provider)&.parse_stream(nil, nil, 200, snapshot[:events])
      return finalize(parsed, snapshot) if parsed

      build_unknown_usage(snapshot)
    end

    def finalize(parsed, snapshot)
      parsed.with(
        provider: @provider,
        model: present_model(parsed.model) || snapshot[:model]
      )
    end

    def present_model(value)
      return nil if value.nil?

      string = value.to_s
      return nil if string.empty? || string == "unknown"

      string
    end

    def build_from_explicit_usage(snapshot)
      explicit = snapshot[:explicit_usage]
      input = explicit[:input_tokens]
      output = explicit[:output_tokens]
      extras = explicit.except(:input_tokens, :output_tokens)

      ParsedUsage.build(
        provider: @provider,
        model: snapshot[:model],
        input_tokens: input,
        output_tokens: output,
        total_tokens: input + output,
        stream: true,
        usage_source: :manual,
        **extras
      )
    end

    def build_unknown_usage(snapshot)
      ParsedUsage.build(
        provider: @provider,
        model: snapshot[:model],
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        stream: true,
        usage_source: :unknown
      )
    end

    def error_metadata(errored) = errored ? { stream_errored: true } : {}

    def elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at) * 1000).round
  end
end
