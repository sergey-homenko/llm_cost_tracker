# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "json"

require_relative "sse"
require_relative "../timing"

module LlmCostTracker
  module Capture
    class StreamCollector
      attr_reader :provider

      def initialize(provider:,
                     model:,
                     latency_ms: nil,
                     provider_response_id: nil,
                     provider_project_id: nil,
                     provider_api_key_id: nil,
                     provider_workspace_id: nil,
                     pricing_mode: nil,
                     metadata: {},
                     context_tags: nil,
                     request: nil)
        @provider = provider.to_s
        @model = model
        @latency_ms = latency_ms
        @provider_response_id = provider_response_id
        @provider_project_id = provider_project_id
        @provider_api_key_id = provider_api_key_id
        @provider_workspace_id = provider_workspace_id
        @pricing_mode = pricing_mode
        @metadata = (metadata || {}).deep_dup
        @context_tags = (context_tags || LlmCostTracker::Tags::Context.tags).deep_dup
        @request = request
        @events = []
        @captured_bytes = 0
        @overflowed = false
        @explicit_usage = nil
        @started_at = LlmCostTracker::Timing.now_monotonic
        @finished = false
        @recording = false
        @mutex = Mutex.new
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
      end

      def usage(input_tokens:, output_tokens:, **extra)
        if extra.key?(:batch)
          raise ArgumentError,
                "`batch:` is no longer accepted by stream.usage; " \
                "pass `pricing_mode: :batch` to track_stream"
        end

        @mutex.synchronize do
          ensure_open!
          @provider_response_id = extra.delete(:provider_response_id) || @provider_response_id
          @provider_project_id = extra.delete(:provider_project_id) || @provider_project_id
          @provider_api_key_id = extra.delete(:provider_api_key_id) || @provider_api_key_id
          @provider_workspace_id = extra.delete(:provider_workspace_id) || @provider_workspace_id
          @explicit_usage = Usage::TokenUsage.build(
            **extra.slice(*Usage::TokenUsage.members),
            input_tokens: input_tokens,
            output_tokens: output_tokens
          )
        end
      end

      def finish!(errored: false)
        snapshot = claim_recording_slot
        return if snapshot.nil?

        record_snapshot(snapshot, errored: errored)
      end

      private

      def claim_recording_slot
        @mutex.synchronize do
          return nil if @finished || @recording

          @recording = true
          pricing_mode = Pricing::Mode.normalize(@pricing_mode)
          {
            events: @events.dup,
            overflowed: @overflowed,
            explicit_usage: @explicit_usage,
            model: @model,
            latency_ms: @latency_ms,
            provider_response_id: @provider_response_id,
            capture_dimensions: capture_dimensions,
            pricing_mode: pricing_mode,
            metadata: @metadata.deep_dup,
            context_tags: @context_tags.deep_dup,
            request: @request
          }
        end
      end

      def record_snapshot(snapshot, errored:)
        save_succeeded = false
        begin
          event = build_event(snapshot)
          provider_response_id = event.provider_response_id || snapshot[:provider_response_id]
          event = event.with(provider_response_id: provider_response_id)

          Tracker.record(
            event: event,
            latency_ms: snapshot[:latency_ms] || LlmCostTracker::Timing.elapsed_ms(@started_at),
            pricing_mode: Pricing::Mode.merge(event.pricing_mode, snapshot[:pricing_mode]),
            metadata: (errored ? { stream_errored: true } : {}).merge(snapshot[:metadata]),
            context_tags: snapshot[:context_tags]
          ) { save_succeeded = true }
        ensure
          @mutex.synchronize do
            @finished = save_succeeded
            @recording = false
          end
        end
      end

      def capture_dimensions
        {
          provider_project_id: @provider_project_id.to_s.strip.presence,
          provider_api_key_id: @provider_api_key_id.to_s.strip.presence,
          provider_workspace_id: @provider_workspace_id.to_s.strip.presence
        }.compact
      end

      def ensure_open!
        return unless @finished

        raise FrozenError, "can't modify finished LlmCostTracker::Capture::StreamCollector"
      end

      def build_event(snapshot)
        return build_from_explicit_usage(snapshot) if snapshot[:explicit_usage]
        return build_unknown_usage(snapshot) if snapshot[:overflowed]

        event = Parsers.find_for_provider(@provider)&.parse_stream(
          response_status: 200,
          events: snapshot[:events],
          request_body: request_body_for(snapshot[:request])
        )
        if event
          model = present_model(event.model) || present_model(snapshot[:model]) || Event::UNKNOWN_MODEL
          return event.with(provider: @provider, model: model, **snapshot.fetch(:capture_dimensions))
        end

        build_unknown_usage(snapshot)
      end

      def request_body_for(request)
        return nil unless request

        JSON.generate(request)
      rescue StandardError
        nil
      end

      def present_model(value)
        string = value.to_s.presence
        string unless string == Event::UNKNOWN_MODEL
      end

      def build_from_explicit_usage(snapshot)
        Event.build(
          provider: @provider,
          model: snapshot[:model] || Event::UNKNOWN_MODEL,
          token_usage: snapshot[:explicit_usage],
          stream: true,
          usage_source: Capture::UsageSource::MANUAL,
          pricing_mode: snapshot[:pricing_mode],
          **snapshot.fetch(:capture_dimensions)
        )
      end

      def build_unknown_usage(snapshot)
        Event.build(
          provider: @provider,
          model: snapshot[:model] || Event::UNKNOWN_MODEL,
          token_usage: Usage::TokenUsage.build(input_tokens: 0, output_tokens: 0, total_tokens: 0),
          stream: true,
          usage_source: Capture::UsageSource::UNKNOWN,
          pricing_mode: snapshot[:pricing_mode],
          **snapshot.fetch(:capture_dimensions)
        )
      end

      IGNORED_PAYLOAD_KEYS = %w[b64_json partial_image_b64].freeze
      private_constant :IGNORED_PAYLOAD_KEYS

      HEAVY_STRING_BYTES = 8 * 1024
      private_constant :HEAVY_STRING_BYTES

      def capture_event(data, type:)
        event = { event: type, data: strip_heavy_payload(data) }
        size = approximate_bytesize(event)
        if @captured_bytes + size <= Capture::SSE::LIMIT_BYTES
          @events << event
          @captured_bytes += size
        else
          @overflowed = true
        end
      rescue TypeError, SystemStackError
        @overflowed = true
      end

      def strip_heavy_payload(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested), out|
            next if IGNORED_PAYLOAD_KEYS.include?(key.to_s)

            out[key] = strip_heavy_payload(nested)
          end
        when Array
          value.map { |nested| strip_heavy_payload(nested) }
        when String
          value.bytesize > HEAVY_STRING_BYTES ? "" : value
        else
          value
        end
      end

      def approximate_bytesize(value)
        case value
        when Hash
          value.sum { |key, nested| approximate_bytesize(key) + approximate_bytesize(nested) + 4 }
        when Array
          value.sum { |nested| approximate_bytesize(nested) + 2 }
        when Numeric, true, false, nil
          8
        else
          value.to_s.bytesize + 2
        end
      end
    end
  end
end
