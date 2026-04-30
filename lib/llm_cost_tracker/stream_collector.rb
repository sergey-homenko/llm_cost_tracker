# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"

require_relative "stream_capture"

module LlmCostTracker
  class StreamCollector
    attr_reader :provider

    def initialize(provider:, model:, latency_ms: nil, provider_response_id: nil, pricing_mode: nil, metadata: {})
      @provider = provider.to_s
      @model = model
      @latency_ms = latency_ms
      @provider_response_id = provider_response_id
      @pricing_mode = pricing_mode
      @metadata = (metadata || {}).deep_dup
      @events = []
      @captured_bytes = 0
      @overflowed = false
      @explicit_usage = nil
      @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @finished = false
      @mutex = Mutex.new
    end

    def model
      @mutex.synchronize { @model }
    end

    def metadata
      @mutex.synchronize { @metadata.deep_dup }
    end

    def provider_response_id
      @mutex.synchronize { @provider_response_id }
    end

    def model=(value)
      @mutex.synchronize do
        ensure_open!
        @model = value
      end
    end

    def provider_response_id=(value)
      @mutex.synchronize do
        ensure_open!
        @provider_response_id = value
      end
    end

    def event(data, type: nil)
      @mutex.synchronize do
        ensure_open!
        capture_event(data, type: type) unless data.nil?
      end
      self
    end

    def usage(input_tokens:, output_tokens:, **extra)
      @mutex.synchronize do
        ensure_open!
        @provider_response_id = extra.delete(:provider_response_id) || @provider_response_id
        @explicit_usage = TokenUsage.from_hash(extra.merge(
                                                 input_tokens: input_tokens.to_i,
                                                 output_tokens: output_tokens.to_i
                                               ))
      end
      self
    end

    def finish!(errored: false)
      snapshot = @mutex.synchronize do
        return if @finished

        @finished = true
        {
          events: @events.dup,
          overflowed: @overflowed,
          explicit_usage: @explicit_usage,
          model: @model,
          latency_ms: @latency_ms,
          provider_response_id: @provider_response_id,
          pricing_mode: @pricing_mode,
          metadata: @metadata.deep_dup
        }
      end

      parsed = build_parsed_usage(snapshot)
      Tracker.record(
        provider: parsed.provider,
        model: parsed.model,
        token_usage: parsed.token_usage,
        latency_ms: snapshot[:latency_ms] ||
          ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at) * 1000).round,
        stream: true,
        usage_source: parsed.usage_source,
        provider_response_id: parsed.provider_response_id || snapshot[:provider_response_id],
        pricing_mode: snapshot[:pricing_mode],
        metadata: (errored ? { stream_errored: true } : {}).merge(snapshot[:metadata])
      )
    end

    private

    def ensure_open!
      return unless @finished

      raise FrozenError, "can't modify finished LlmCostTracker::StreamCollector"
    end

    def build_parsed_usage(snapshot)
      return build_from_explicit_usage(snapshot) if snapshot[:explicit_usage]
      return build_unknown_usage(snapshot) if snapshot[:overflowed]

      parsed = Parsers::Lookup.find_for_provider(@provider)&.parse_stream(nil, nil, 200, snapshot[:events])
      return finalize(parsed, snapshot) if parsed

      build_unknown_usage(snapshot)
    end

    def finalize(parsed, snapshot)
      parsed.with(
        provider: @provider,
        model: present_model(parsed.model) || present_model(snapshot[:model]) || ParsedUsage::UNKNOWN_MODEL
      )
    end

    def present_model(value)
      return nil if value.nil?

      string = value.to_s.presence
      return nil if string.nil? || string == "unknown"

      string
    end

    def build_from_explicit_usage(snapshot)
      ParsedUsage.build(
        provider: @provider,
        model: snapshot[:model] || ParsedUsage::UNKNOWN_MODEL,
        token_usage: snapshot[:explicit_usage],
        stream: true,
        usage_source: :manual
      )
    end

    def build_unknown_usage(snapshot)
      ParsedUsage.build(
        provider: @provider,
        model: snapshot[:model] || ParsedUsage::UNKNOWN_MODEL,
        token_usage: TokenUsage.build(input_tokens: 0, output_tokens: 0, total_tokens: 0),
        stream: true,
        usage_source: :unknown
      )
    end

    def capture_event(data, type:)
      size = type.to_s.bytesize + estimated_bytes(data) + 32
      if @captured_bytes + size <= StreamCapture::LIMIT_BYTES
        @events << { event: type, data: data.deep_dup }
        @captured_bytes += size
      else
        @overflowed = true
        @events.clear
      end
    end

    def estimated_bytes(value)
      case value
      when Hash
        value.sum { |key, nested| estimated_bytes(key) + estimated_bytes(nested) + 4 }
      when Array
        value.sum { |nested| estimated_bytes(nested) + 2 }
      when String
        value.bytesize + 2
      when Numeric, true, false, nil
        value.to_s.bytesize
      else
        value.to_s.bytesize + 2
      end
    end
  end
end
