# frozen_string_literal: true

module LlmCostTracker
  class StreamCollector
    attr_reader :provider, :metadata
    attr_accessor :model

    def initialize(provider:, model:, latency_ms: nil, metadata: {})
      @provider = provider.to_s
      @model = model
      @latency_ms = latency_ms
      @metadata = metadata
      @events = []
      @explicit_usage = nil
      @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @finished = false
    end

    def event(data, type: nil)
      @events << { event: type, data: data } unless data.nil?
      self
    end
    alias chunk event

    def usage(input_tokens:, output_tokens:, **extra)
      @explicit_usage = extra.merge(
        input_tokens: input_tokens.to_i,
        output_tokens: output_tokens.to_i
      )
      self
    end

    def finish!(errored: false)
      return if @finished

      @finished = true
      parsed = build_parsed_usage
      Tracker.record(
        provider: parsed.provider,
        model: parsed.model,
        input_tokens: parsed.input_tokens,
        output_tokens: parsed.output_tokens,
        latency_ms: @latency_ms || elapsed_ms,
        stream: true,
        usage_source: parsed.usage_source,
        metadata: error_metadata(errored).merge(@metadata).merge(parsed.metadata)
      )
    end

    private

    def build_parsed_usage
      return build_from_explicit_usage if @explicit_usage

      parsed = Parsers::Registry.find_for_provider(@provider)&.parse_stream(nil, nil, 200, @events)
      return finalize(parsed) if parsed

      build_unknown_usage
    end

    def finalize(parsed)
      parsed.with(
        provider: @provider,
        model: present_model(parsed.model) || @model
      )
    end

    def present_model(value)
      return nil if value.nil?

      string = value.to_s
      return nil if string.empty? || string == "unknown"

      string
    end

    def build_from_explicit_usage
      input = @explicit_usage[:input_tokens]
      output = @explicit_usage[:output_tokens]
      extras = @explicit_usage.except(:input_tokens, :output_tokens)

      ParsedUsage.build(
        provider: @provider,
        model: @model,
        input_tokens: input,
        output_tokens: output,
        total_tokens: input + output,
        stream: true,
        usage_source: :manual,
        **extras
      )
    end

    def build_unknown_usage
      ParsedUsage.build(
        provider: @provider,
        model: @model,
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        stream: true,
        usage_source: :unknown
      )
    end

    def error_metadata(errored)
      errored ? { stream_errored: true } : {}
    end

    def elapsed_ms
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at) * 1000).round
    end
  end
end
