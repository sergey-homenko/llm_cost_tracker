# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "json"

require_relative "event_window"
require_relative "sdk_payload"
require_relative "../timing"

module LlmCostTracker
  module Capture
    class StreamCollector
      DIMENSIONS = %i[provider_project_id provider_api_key_id provider_workspace_id].freeze
      Snapshot = Data.define(*%i[events overflowed explicit_usage model latency_ms provider_response_id
                                 capture_dimensions pricing_mode metadata context_tags request])
      private_constant :DIMENSIONS, :Snapshot

      attr_reader :provider

      def initialize(provider:,
                     model:,
                     parsed_as: provider,
                     latency_ms: nil,
                     provider_response_id: nil,
                     provider_project_id: nil,
                     provider_api_key_id: nil,
                     provider_workspace_id: nil,
                     pricing_mode: nil,
                     metadata: {},
                     request: nil)
        @provider = provider.to_s
        @parsed_as = parsed_as.to_s
        @model = model
        @latency_ms = latency_ms
        @provider_response_id = provider_response_id
        @dimensions = { provider_project_id:, provider_api_key_id:, provider_workspace_id: }
        @pricing_mode = pricing_mode
        @metadata = (metadata || {}).deep_dup
        @context_tags = LlmCostTracker::Tags::Context.tags.deep_dup
        @request = request
        @window = parser_window
        @explicit_usage = nil
        @started_at = LlmCostTracker::Timing.now_monotonic
        @state = :open
        @mutex = Mutex.new
      end

      def model=(value)
        modify { @model = value }
      end

      def provider_response_id=(value)
        modify { @provider_response_id = value }
      end

      def event(data, type: nil)
        data = SdkPayload.normalize(data) if data.is_a?(Hash)
        modify { @window.push(data, type: type&.to_s) unless data.nil? }
      end

      def usage(input_tokens:, output_tokens:, **extra)
        if extra.key?(:batch)
          raise ArgumentError,
                "`batch:` is no longer accepted by stream.usage; " \
                "pass `pricing_mode: :batch` to track_stream"
        end

        modify do
          @provider_response_id = extra.delete(:provider_response_id) || @provider_response_id
          DIMENSIONS.each { |key| @dimensions[key] = extra.delete(key) || @dimensions[key] }
          @explicit_usage = Usage::TokenUsage.build(**extra, input_tokens: input_tokens, output_tokens: output_tokens)
        end
      end

      def finish!(errored: false)
        snapshot = claim_recording_slot
        return if snapshot.nil?

        record_snapshot(snapshot, errored: errored)
      rescue TransactionAbortedError
        raise
      rescue ActiveRecord::RecordNotUnique
        nil
      rescue StandardError => e
        raise unless errored

        Logging.warn("Recording an errored stream raised #{e.class}: #{e.message}; kept the stream's own exception")
      end

      private

      def modify
        @mutex.synchronize do
          raise FrozenError, "can't modify finished LlmCostTracker::Capture::StreamCollector" if @state == :finished

          yield
        end
      end

      def parser_window
        parser = Parsers.find_for_provider(@parsed_as)
        EventWindow.new(notable: parser&.method(:retain_stream_event?), trim: parser&.method(:trim_stream_event))
      end

      def claim_recording_slot
        @mutex.synchronize do
          return nil unless @state == :open

          @state = :recording
          snapshot
        end
      end

      def snapshot
        pricing_mode = Pricing::Mode.normalize(@pricing_mode)
        Snapshot.new(
          events: @window.events,
          overflowed: @window.overflowed?,
          explicit_usage: @explicit_usage,
          model: @model,
          latency_ms: @latency_ms,
          provider_response_id: @provider_response_id,
          capture_dimensions: @dimensions.transform_values { |value| value.to_s.strip.presence }.compact,
          pricing_mode: pricing_mode,
          metadata: @metadata.deep_dup,
          context_tags: @context_tags.deep_dup,
          request: @request
        )
      end

      def record_snapshot(snapshot, errored:)
        saved = false
        Tracker.record(
          event: event_for(snapshot),
          latency_ms: snapshot.latency_ms || LlmCostTracker::Timing.elapsed_ms(@started_at),
          metadata: (errored ? { stream_errored: true } : {}).merge(snapshot.metadata),
          context_tags: snapshot.context_tags
        ) { saved = true }
      ensure
        @mutex.synchronize do
          @state = saved ? :finished : :open
          release_buffers if saved
        end
      end

      def release_buffers
        @window = EventWindow.new
        @request = nil
      end

      def event_for(snapshot)
        event = build_event(snapshot)
        event.with(
          provider_response_id: event.provider_response_id || snapshot.provider_response_id,
          pricing_mode: Pricing::Mode.merge(event.pricing_mode, snapshot.pricing_mode)
        )
      end

      def build_event(snapshot)
        return build_unparsed_event(snapshot) if snapshot.explicit_usage
        return overflowed_event(snapshot) if snapshot.overflowed

        parsed = parse_events(snapshot)
        return build_unparsed_event(snapshot) unless parsed

        model = present_model(parsed.model) || present_model(snapshot.model) || Event::UNKNOWN_MODEL
        parsed.with(provider: @provider, model: model, **snapshot.capture_dimensions)
      end

      def overflowed_event(snapshot)
        Logging.warn("#{@provider} stream events exceeded #{SSE::LIMIT_BYTES} bytes; " \
                     "recording usage_source=#{Usage::Source::UNKNOWN}.")
        build_unparsed_event(snapshot)
      end

      def parse_events(snapshot)
        request_body = request_body_for(snapshot.request)
        events = Parsers.all_for_provider(@parsed_as).filter_map do |parser|
          parser.parse_stream(
            response_status: 200, events: snapshot.events, request_body: request_body, model: snapshot.model
          )
        end
        events.find { |parsed| parsed.usage_source != Usage::Source::UNKNOWN } || events.first
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

      def build_unparsed_event(snapshot)
        explicit_usage = snapshot.explicit_usage
        Event.build(
          provider: @provider,
          model: snapshot.model || Event::UNKNOWN_MODEL,
          token_usage: explicit_usage || Usage::TokenUsage.build(input_tokens: 0, output_tokens: 0, total_tokens: 0),
          stream: true,
          usage_source: explicit_usage ? Usage::Source::MANUAL : Usage::Source::UNKNOWN,
          pricing_mode: snapshot.pricing_mode,
          **snapshot.capture_dimensions
        )
      end
    end
  end
end
