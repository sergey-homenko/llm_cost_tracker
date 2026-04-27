# frozen_string_literal: true

require "faraday"
require "json"

require_relative "../logging"
require_relative "../request_url"
require_relative "../stream_capture"

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
        request_body = read_body(request_env.body) || ""
        parser       = Parsers::Registry.find_for(request_url)
        streaming    = parser&.streaming_request?(request_url, request_body)
        stream_buffer = install_stream_tap(request_env) if streaming

        Tracker.enforce_budget! if parser
        started_at = monotonic_time

        @app.call(request_env).on_complete do |response_env|
          process(
            parser: parser,
            request_env: request_env,
            request_url: request_url,
            request_body: request_body,
            response_env: response_env,
            latency_ms: elapsed_ms(started_at),
            streaming: streaming,
            stream_buffer: stream_buffer
          )
        end
      end

      private

      def process(parser:, request_env:, request_url:, request_body:, response_env:,
                  latency_ms:, streaming:, stream_buffer:)
        return unless parser

        parsed =
          if streaming
            parse_stream(parser, request_url, request_body, response_env, stream_buffer)
          else
            parse_response(parser, request_url, request_body, response_env)
          end
        return unless parsed

        Tracker.record(
          provider: parsed.provider,
          model: parsed.model,
          input_tokens: parsed.input_tokens,
          output_tokens: parsed.output_tokens,
          latency_ms: latency_ms,
          stream: parsed.stream,
          usage_source: parsed.usage_source,
          provider_response_id: parsed.provider_response_id,
          metadata: resolved_tags(request_env).merge(parsed.metadata)
        )
      rescue LlmCostTracker::Error
        raise
      rescue StandardError => e
        Logging.warn("Error processing response: #{e.class}: #{e.message}")
      end

      def parse_response(parser, request_url, request_body, response_env)
        response_body = read_body(response_env.body)
        unless response_body
          Logging.warn(
            "Unable to read response body for #{RequestUrl.label(request_url)}; " \
            "known streaming responses are captured automatically, or via LlmCostTracker.track_stream " \
            "for custom clients."
          )
          return nil
        end

        parser.parse(request_url, request_body, response_env.status, response_body)
      end

      def parse_stream(parser, request_url, request_body, response_env, stream_buffer)
        body = stream_buffer&.dig(:buffer)&.string
        body = read_body(response_env.body) if body.nil? || body.empty?

        if body.nil? || body.empty?
          Logging.warn(capture_warning(request_url, stream_buffer))
          return parser.parse_stream(request_url, request_body, response_env.status, [])
        end

        events = Parsers::SSE.parse(body)
        parser.parse_stream(request_url, request_body, response_env.status, events)
      end

      def install_stream_tap(request_env)
        return nil unless request_env.respond_to?(:request) && request_env.request

        original = request_env.request.on_data
        return nil unless original

        state = { buffer: StringIO.new, bytes: 0, overflowed: false }
        request_env.request.on_data = proc do |chunk, size, env|
          chunk = chunk.to_s
          unless state[:overflowed]
            if state[:bytes] + chunk.bytesize <= StreamCapture::LIMIT_BYTES
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
          body.respond_to?(:to_str) ? body.to_str : nil
        end
      end

      def resolved_tags(request_env)
        tags = @tags.respond_to?(:call) ? call_tags(request_env) : @tags
        return {} if tags.nil?

        tags.to_h
      end

      def call_tags(request_env)
        @tags.arity.zero? ? @tags.call : @tags.call(request_env)
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def elapsed_ms(started_at)
        ((monotonic_time - started_at) * 1000).round
      end

      def capture_warning(request_url, stream_buffer)
        unless stream_buffer&.dig(:overflowed)
          return "Unable to capture streaming response for #{RequestUrl.label(request_url)}; " \
                 "recording usage_source=unknown. Use LlmCostTracker.track_stream for manual capture."
        end

        "Streaming response for #{RequestUrl.label(request_url)} exceeded #{StreamCapture::LIMIT_BYTES} bytes; " \
          "recording usage_source=unknown. Use LlmCostTracker.track_stream for manual capture."
      end
    end
  end
end
