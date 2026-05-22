# frozen_string_literal: true

require "faraday"
require "json"
require "stringio"
require "uri"

require_relative "../capture/sse"
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
        return @app.call(request_env) unless enabled?

        request_url  = request_env.url.to_s
        request_body = read_body(request_env.body)
        parser       = Parsers.find_for(request_url)
        request_parsed = parser ? safe_json_parse(request_body) : nil
        streaming = parser&.streaming_request?(request_url, request_parsed)
        if streaming
          request_body = inject_stream_usage_flag(request_env, parser, request_url, request_parsed) || request_body
        end
        stream_buffer = install_stream_tap(request_env) if streaming

        if parser
          Tracker.enforce_budget!(
            provider: parser.provider_for(request_url),
            model: parser.model_for(request_url, request_parsed),
            request: request_parsed
          )
        end
        context_tags, metadata = tag_snapshot(request_env) if parser
        started_at = LlmCostTracker::Timing.now_monotonic

        invoke_app_with_capture(
          request_env: request_env, parser: parser, request_url: request_url,
          request_body: request_body, streaming: streaming, stream_buffer: stream_buffer,
          context_tags: context_tags, metadata: metadata, started_at: started_at
        )
      end

      private

      def enabled?
        return @enabled if defined?(@enabled)

        @enabled = LlmCostTracker.configuration.enabled
      end

      def safe_json_parse(body)
        return {} if body.nil? || body.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        {}
      end

      def auto_enable_stream_usage?
        return @auto_enable_stream_usage if defined?(@auto_enable_stream_usage)

        @auto_enable_stream_usage = LlmCostTracker.configuration.auto_enable_stream_usage
      end

      def invoke_app_with_capture(request_env:, parser:, request_url:, request_body:, streaming:,
                                  stream_buffer:, context_tags:, metadata:, started_at:)
        response_received = false
        @app.call(request_env).on_complete do |response_env|
          response_received = true
          process(
            parser: parser, request_url: request_url, request_body: request_body,
            response_env: response_env, latency_ms: LlmCostTracker::Timing.elapsed_ms(started_at),
            streaming: streaming, stream_buffer: stream_buffer,
            context_tags: context_tags, metadata: metadata
          )
        end
      rescue StandardError => e
        if streaming && parser && !response_received
          process_interrupted_stream(
            parser: parser, request_url: request_url, request_body: request_body,
            latency_ms: LlmCostTracker::Timing.elapsed_ms(started_at),
            context_tags: context_tags, metadata: metadata, error: e
          )
        end
        raise
      end

      def inject_stream_usage_flag(request_env, parser, request_url, request_parsed)
        return nil unless auto_enable_stream_usage?
        return nil unless parser&.auto_enable_stream_usage?(request_url)

        stream_options = request_parsed["stream_options"]
        return nil if stream_options.is_a?(Hash) && stream_options.key?("include_usage")

        request_parsed["stream_options"] = (stream_options || {}).merge("include_usage" => true)
        new_body = request_parsed.to_json
        request_env.body = new_body
        new_body
      end

      def process_interrupted_stream(parser:, request_url:, request_body:, latency_ms:,
                                     context_tags:, metadata:, error:)
        request = parser.safe_json_parse(request_body)
        event = Event.build(
          provider: parser.provider_for(request_url),
          model: request["model"] || Event::UNKNOWN_MODEL,
          token_usage: TokenUsage.build(input_tokens: 0, output_tokens: 0, total_tokens: 0),
          stream: true,
          usage_source: :unknown
        )
        merged_metadata = (metadata || {}).merge(
          stream_interrupted: true,
          stream_interrupted_error: "#{error.class}: #{error.message}"
        )
        Tracker.record(
          event: event,
          latency_ms: latency_ms,
          metadata: merged_metadata,
          context_tags: context_tags
        )
      rescue StandardError => e
        Logging.warn("Error recording interrupted stream: #{e.class}: #{e.message}")
      end

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
          event: parsed,
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
        overflowed = stream_buffer&.dig(:overflowed) == true
        Logging.warn(capture_warning(request_url, stream_buffer)) if overflowed

        body = stream_buffer&.dig(:buffer)&.string
        body = read_body(response_env.body) if body.blank?

        if body.blank?
          Logging.warn(capture_warning(request_url, stream_buffer)) unless overflowed
          return parser.parse_stream(
            request_url: request_url,
            request_body: request_body,
            response_status: response_env.status,
            response_headers: response_env.response_headers
          )
        end

        events = overflowed ? [] : Capture::SSE.parse(body)
        parser.parse_stream(
          request_url: request_url,
          request_body: request_body,
          response_status: response_env.status,
          events: events,
          response_headers: response_env.response_headers
        )
      end

      def forward_on_data_chunk(callable, chunk, size, env)
        arity = callable.arity
        return callable.call(chunk, size, env) if arity.negative?

        case arity
        when 0, 1 then callable.call(chunk)
        when 2 then callable.call(chunk, size)
        else callable.call(chunk, size, env)
        end
      end

      def install_stream_tap(request_env)
        request = request_env.request
        return nil unless request

        original = request.on_data
        return nil unless original

        state = { buffer: StringIO.new, bytes: 0, overflowed: false }
        request.on_data = proc do |chunk, size, env|
          chunk = chunk.to_s
          remaining = Capture::Stream::LIMIT_BYTES - state[:bytes]
          if chunk.bytesize <= remaining
            state[:buffer] << chunk
            state[:bytes] += chunk.bytesize
          else
            state[:buffer] << chunk.byteslice(0, remaining) if remaining.positive?
            state[:bytes] += [remaining, 0].max
            state[:overflowed] = true
          end
          forward_on_data_chunk(original, chunk, size, env)
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
