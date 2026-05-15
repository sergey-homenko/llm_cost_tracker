# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "json"

require_relative "stream"
require_relative "../pricing/mode"
require_relative "../timing"

module LlmCostTracker
  module Capture
    class StreamCollector
      attr_reader :provider

      def initialize(provider:, model:, latency_ms: nil, provider_response_id: nil, provider_project_id: nil,
                     provider_api_key_id: nil, provider_workspace_id: nil, batch: nil, pricing_mode: nil,
                     metadata: {}, context_tags: nil, request: nil)
        @provider = provider.to_s
        @model = model
        @latency_ms = latency_ms
        @provider_response_id = provider_response_id
        @provider_project_id = provider_project_id
        @provider_api_key_id = provider_api_key_id
        @provider_workspace_id = provider_workspace_id
        @batch = batch
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
      end

      def usage(input_tokens:, output_tokens:, **extra)
        @mutex.synchronize do
          ensure_open!
          @provider_response_id = extra.delete(:provider_response_id) || @provider_response_id
          @provider_project_id = extra.delete(:provider_project_id) || @provider_project_id
          @provider_api_key_id = extra.delete(:provider_api_key_id) || @provider_api_key_id
          @provider_workspace_id = extra.delete(:provider_workspace_id) || @provider_workspace_id
          batch = extra.delete(:batch)
          @batch = batch unless batch.nil?
          @explicit_usage = TokenUsage.build(
            **extra.slice(*TokenUsage.members),
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
          pricing_mode = Pricing.normalize_mode(@pricing_mode)
          {
            events: @events.dup,
            overflowed: @overflowed,
            explicit_usage: @explicit_usage,
            model: @model,
            latency_ms: @latency_ms,
            provider_response_id: @provider_response_id,
            capture_dimensions: capture_dimensions(pricing_mode),
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
            pricing_mode: merge_pricing_modes(event.pricing_mode, snapshot[:pricing_mode]),
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

      HOST_DERIVED_MODE_TOKENS = %i[data_residency].freeze
      private_constant :HOST_DERIVED_MODE_TOKENS

      def merge_pricing_modes(provider_mode, request_mode)
        return Pricing.normalize_mode(request_mode) if provider_mode.to_s.strip.empty?

        provider_tokens = Pricing::Mode.tokenize(provider_mode) - Pricing::STANDARD_MODE_VALUES
        request_host_tokens = Pricing::Mode.tokenize(request_mode || "") & HOST_DERIVED_MODE_TOKENS
        combined = provider_tokens | request_host_tokens
        return nil if combined.empty?

        Pricing.normalize_mode(combined.join("_"))
      end

      def capture_dimensions(pricing_mode)
        batch = @batch.nil? ? Event.batch_from_pricing_mode?(pricing_mode).presence : @batch
        {
          provider_project_id: @provider_project_id.to_s.strip.presence,
          provider_api_key_id: @provider_api_key_id.to_s.strip.presence,
          provider_workspace_id: @provider_workspace_id.to_s.strip.presence,
          batch: batch
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
        return nil if value.nil?

        string = value.to_s.presence
        return nil if string.nil? || string == "unknown"

        string
      end

      def build_from_explicit_usage(snapshot)
        Event.build(
          provider: @provider,
          model: snapshot[:model] || Event::UNKNOWN_MODEL,
          token_usage: snapshot[:explicit_usage],
          stream: true,
          usage_source: :manual,
          pricing_mode: snapshot[:pricing_mode],
          **snapshot.fetch(:capture_dimensions)
        )
      end

      def build_unknown_usage(snapshot)
        Event.build(
          provider: @provider,
          model: snapshot[:model] || Event::UNKNOWN_MODEL,
          token_usage: TokenUsage.build(input_tokens: 0, output_tokens: 0, total_tokens: 0),
          stream: true,
          usage_source: :unknown,
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
        if @captured_bytes + size <= Capture::Stream::LIMIT_BYTES
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
