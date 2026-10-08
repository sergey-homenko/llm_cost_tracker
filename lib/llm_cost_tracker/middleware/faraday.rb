# frozen_string_literal: true

require "faraday"
require "json"
require "uri"

require_relative "../capture/sse"
require_relative "../capture/stream_tap"
require_relative "../timing"

module LlmCostTracker
  module Middleware
    class Faraday < ::Faraday::Middleware
      MULTIPART_MODEL = /name="model"\r\n(?:[^\r\n]+\r\n)*\r\n([^\r\n]+)\r\n/

      def initialize(app, **options)
        super(app)
        @tags = options.fetch(:tags, {})
      end

      def call(request_env)
        return @app.call(request_env) unless LlmCostTracker.configuration.enabled

        request_url  = request_env.url.to_s
        parser       = Parsers.find_for(request_url)
        request_body = read_body(request_env.body) || multipart_model_body(request_env, parser)
        request_parsed = parser&.safe_json_parse(request_body)
        streaming = parser&.streaming_request?(request_url, request_parsed)
        if streaming
          request_body = inject_stream_usage_flag(request_env, parser, request_url, request_parsed) || request_body
        end
        stream_buffer = install_stream_tap(request_env, parser) if streaming

        checked = parser || (request_env.method == :post && Parsers.batch_submission?(request_env.url))
        context_tags, metadata = tag_snapshot(request_env) if checked
        if checked && request_env.method == :post
          Budget.enforce!(
            provider: parser&.provider_for(request_url),
            model: parser&.model_for(request_url, request_parsed),
            request: request_parsed,
            tags: Tracker.build_tags(context_tags: context_tags, metadata: metadata)
          )
        end
        started_at = LlmCostTracker::Timing.now_monotonic

        invoke_app_with_capture(
          request_env: request_env,
          parser: parser,
          request_url: request_url,
          request_body: request_body,
          streaming: streaming,
          stream_buffer: stream_buffer,
          context_tags: context_tags,
          metadata: metadata,
          started_at: started_at
        )
      end

      private

      def invoke_app_with_capture(request_env:,
                                  parser:,
                                  request_url:,
                                  request_body:,
                                  streaming:,
                                  stream_buffer:,
                                  context_tags:,
                                  metadata:,
                                  started_at:)
        response_received = false
        @app.call(request_env).on_complete do |response_env|
          response_received = true
          process(
            parser: parser,
            request_url: request_url,
            request_body: request_body,
            response_env: response_env,
            latency_ms: (LlmCostTracker::Timing.elapsed_ms(started_at) if request_env.method == :post),
            streaming: streaming,
            stream_buffer: stream_buffer,
            context_tags: context_tags,
            metadata: metadata
          )
        end
      rescue StandardError => e
        if streaming && parser && !response_received
          process_interrupted_stream(
            parser: parser,
            request_url: request_url,
            request_body: request_body,
            latency_ms: LlmCostTracker::Timing.elapsed_ms(started_at),
            context_tags: context_tags,
            metadata: metadata,
            error: e
          )
        end
        raise
      end

      def inject_stream_usage_flag(request_env, parser, request_url, request_parsed)
        return nil unless LlmCostTracker.configuration.capture.request_stream_usage
        return nil unless parser.auto_enable_stream_usage?(request_url, request_parsed)

        stream_options = request_parsed["stream_options"]
        return nil if stream_options.is_a?(Hash) && stream_options.key?("include_usage")

        request_parsed["stream_options"] = (stream_options || {}).merge("include_usage" => true)
        new_body = request_parsed.to_json
        request_env.body = new_body
        new_body
      end

      def process_interrupted_stream(parser:,
                                     request_url:,
                                     request_body:,
                                     latency_ms:,
                                     context_tags:,
                                     metadata:,
                                     error:)
        request = parser.safe_json_parse(request_body)
        event = Event.build(
          provider: parser.provider_for(request_url),
          model: parser.model_for(request_url, request) || Event::UNKNOWN_MODEL,
          token_usage: Usage::TokenUsage.build(input_tokens: 0, output_tokens: 0, total_tokens: 0),
          stream: true,
          usage_source: Usage::Source::UNKNOWN
        )
        merged_metadata = (metadata || {}).merge(stream_interrupted: true, stream_interrupted_error: error.class.name)
        status = error.try(:response_status)
        merged_metadata[:stream_interrupted_status] = status if status
        Tracker.record(
          event: event,
          latency_ms: latency_ms,
          metadata: merged_metadata,
          context_tags: context_tags
        )
      rescue LlmCostTracker::TransactionAbortedError
        raise
      rescue StandardError => e
        Logging.warn("Error recording interrupted stream: #{e.class}: #{e.message}")
      end

      def process(parser:,
                  request_url:,
                  request_body:,
                  response_env:,
                  latency_ms:,
                  streaming:,
                  stream_buffer:,
                  context_tags:,
                  metadata:)
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

        Tracker.record(event: parsed, latency_ms: latency_ms, metadata: metadata, context_tags: context_tags) if parsed
      rescue *LlmCostTracker::CALLER_ERRORS
        raise
      rescue ActiveRecord::RecordNotUnique
        nil
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
        parser.parse_stream(
          request_url: request_url,
          request_body: request_body,
          response_status: response_env.status,
          events: stream_events(request_url, response_env, stream_buffer),
          response_headers: response_env.response_headers
        )
      end

      def stream_events(request_url, response_env, stream_buffer)
        if stream_buffer&.received?
          events = stream_buffer.events
          return events unless stream_buffer.overflowed? || stream_buffer.failed?
        else
          body = read_body(response_env.body)
          return Capture::SSE.parse(body) if body.present?
        end

        Logging.warn(capture_warning(request_url, stream_buffer))
        []
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

      def install_stream_tap(request_env, parser)
        request = request_env.request
        return nil unless request

        original = request.on_data
        return nil unless original

        tap = Capture::StreamTap.new(notable: parser.method(:retain_stream_event?),
                                     trim: parser.method(:trim_stream_event))
        request.on_data = proc do |chunk, size, env|
          tap << chunk
          forward_on_data_chunk(original, chunk, size, env)
        end
        tap
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

      def multipart_model_body(request_env, parser)
        body = request_env.body
        multipart = request_env.request_headers["Content-Type"].to_s.start_with?("multipart/form-data")
        return nil unless parser && multipart && body.respond_to?(:read) && body.respond_to?(:rewind)

        model = multipart_model(body)
        model && { "model" => model }.to_json
      rescue StandardError => e
        Logging.warn("Unable to read the model from a multipart request: #{e.class}: #{e.message}")
        nil
      end

      def multipart_model(body)
        window = String.new(encoding: Encoding::BINARY)
        while (chunk = body.read(65_536))
          window << chunk.b
          model = window[MULTIPART_MODEL, 1]
          return model.force_encoding(Encoding::UTF_8) if model

          window = window.byteslice([window.bytesize - 512, 0].max..)
        end
      ensure
        body.rewind
      end

      def resolved_tags(request_env)
        return @tags.to_h unless @tags.respond_to?(:call)

        (@tags.arity.zero? ? @tags.call : @tags.call(request_env)).to_h
      end

      def tag_snapshot(request_env)
        [LlmCostTracker::Tags::Context.tags, resolved_tags(request_env)]
      rescue StandardError => e
        Logging.warn("Error resolving request tags: #{e.class}: #{e.message}")
        [{}, {}]
      end

      def capture_warning(request_url, stream_buffer)
        suffix = "recording usage_source=#{Usage::Source::UNKNOWN}. " \
                 "Use LlmCostTracker.track_stream for manual capture."
        label = request_url_label(request_url)
        return "Unable to capture streaming response for #{label}; #{suffix}" unless stream_buffer&.overflowed?

        "Streaming response for #{label} exceeded #{Capture::SSE::LIMIT_BYTES} bytes; #{suffix}"
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
