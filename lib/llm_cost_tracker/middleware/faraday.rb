# frozen_string_literal: true

require "faraday"
require "json"
require "uri"

require_relative "../logging"
require_relative "../capture/stream"
require_relative "../timing"

module LlmCostTracker
  module Middleware
    class Faraday < ::Faraday::Middleware
      def initialize(app, **options)
        super(app)
        @tags = options.fetch(:tags, {})
      end

      def call(request_env)
        return @app.call(request_env) unless LlmCostTracker.configuration.enabled

        request_url  = request_env.url.to_s
        request_body = read_body(request_env.body)
        parser       = Parsers.find_for(request_url)
        streaming    = parser&.streaming_request?(request_url, request_body)
        stream_buffer = install_stream_tap(request_env) if streaming

        Tracker.enforce_budget! if parser
        context_tags, metadata = tag_snapshot(request_env) if parser
        started_at = LlmCostTracker::Timing.now_monotonic

        @app.call(request_env).on_complete do |response_env|
          process(
            parser: parser,
            request_url: request_url,
            request_body: request_body,
            response_env: response_env,
            latency_ms: LlmCostTracker::Timing.elapsed_ms(started_at),
            streaming: streaming,
            stream_buffer: stream_buffer,
            context_tags: context_tags,
            metadata: metadata
          )
        end
      end

      private

      def process(parser:, request_url:, request_body:, response_env:,
                  latency_ms:, streaming:, stream_buffer:, context_tags:, metadata:)
        return unless parser

        parsed =
          if streaming
            parse_stream(
              parser: parser,
              request_url: request_url,
              request_body: request_body,
              response_env: response_env,
              stream_buffer: stream_buffer
            )
          else
            parse_response(
              parser: parser,
              request_url: request_url,
              request_body: request_body,
              response_env: response_env
            )
          end
        return unless parsed

        Tracker.record(
          capture: parsed,
          latency_ms: latency_ms,
          metadata: metadata,
          context_tags: context_tags
        )
      rescue LlmCostTracker::Error
        raise
      rescue StandardError => e
        Logging.warn("Error processing response: #{e.class}: #{e.message}")
      end

      def parse_response(parser:, request_url:, request_body:, response_env:)
        response_body = read_body(response_env.body)
        unless response_body
          Logging.warn(
            "Unable to read response body for #{request_url_label(request_url)}; " \
            "known streaming responses are captured automatically, or via LlmCostTracker.track_stream " \
            "for custom clients."
          )
          return nil
        end

        parser.parse(
          request_url: request_url,
          request_body: request_body,
          response_status: response_env.status,
          response_body: response_body,
          response_headers: response_env.response_headers
        )
      end

      def parse_stream(parser:, request_url:, request_body:, response_env:, stream_buffer:)
        if stream_buffer&.dig(:overflowed)
          Logging.warn(capture_warning(request_url, stream_buffer))
          return parser.parse_stream(
            request_url: request_url,
            request_body: request_body,
            response_status: response_env.status,
            response_headers: response_env.response_headers
          )
        end

        body = stream_buffer&.dig(:buffer)&.string
        body = read_body(response_env.body) if body.blank?

        if body.blank?
          Logging.warn(capture_warning(request_url, stream_buffer))
          return parser.parse_stream(
            request_url: request_url,
            request_body: request_body,
            response_status: response_env.status,
            response_headers: response_env.response_headers
          )
        end

        events = Parsers::SSE.parse(body)
        parser.parse_stream(
          request_url: request_url,
          request_body: request_body,
          response_status: response_env.status,
          events: events,
          response_headers: response_env.response_headers
        )
      end

      def install_stream_tap(request_env)
        request = request_env.request
        return nil unless request

        original = request.on_data
        return nil unless original

        state = { buffer: StringIO.new, bytes: 0, overflowed: false }
        request.on_data = proc do |chunk, size, env|
          chunk = chunk.to_s
          unless state[:overflowed]
            if state[:bytes] + chunk.bytesize <= Capture::Stream::LIMIT_BYTES
              state[:buffer] << chunk
              state[:bytes] += chunk.bytesize
            else
              state[:overflowed] = true
              state[:buffer] = nil
            end
          end
          original.call(chunk, size, env)
        end
        state
      rescue StandardError => e
        Logging.warn("Unable to install streaming tap: #{e.class}: #{e.message}")
        nil
      end

      def read_body(body)
        case body
        when String then body
        when nil then ""
        when Hash, Array then body.to_json
        else
          body.try(:to_str)
        end
      end

      def resolved_tags(request_env)
        tags =
          if @tags.respond_to?(:call)
            @tags.arity.zero? ? @tags.call : @tags.call(request_env)
          else
            @tags
          end
        return {} if tags.nil?

        tags.to_h
      end

      def tag_snapshot(request_env)
        [LlmCostTracker::Tags::Context.tags, resolved_tags(request_env)]
      rescue StandardError => e
        Logging.warn("Error resolving request tags: #{e.class}: #{e.message}")
        [{}, {}]
      end

      def capture_warning(request_url, stream_buffer)
        unless stream_buffer&.dig(:overflowed)
          return "Unable to capture streaming response for #{request_url_label(request_url)}; " \
                 "recording usage_source=unknown. Use LlmCostTracker.track_stream for manual capture."
        end

        "Streaming response for #{request_url_label(request_url)} exceeded #{Capture::Stream::LIMIT_BYTES} bytes; " \
          "recording usage_source=unknown. Use LlmCostTracker.track_stream for manual capture."
      end

      def request_url_label(value)
        uri = URI.parse(value.to_s)
        uri.query = nil
        uri.fragment = nil
        uri.user = nil
        uri.password = nil
        uri.to_s
      rescue URI::InvalidURIError
        value.to_s.split("?", 2).first
      end
    end
  end
end
