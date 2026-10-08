# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "faraday"

require_relative "../../capture/sse"
require_relative "body"

module LlmCostTracker
  module Middleware
    class Faraday < ::Faraday::Middleware
      ResponseReader = ::Data.define(:parser, :request_url, :request_body, :stream_tap)

      class ResponseReader
        def call(response_env, streaming:)
          streaming ? parse_stream(response_env) : parse_response(response_env)
        end

        private

        def parse_response(response_env)
          response_body = Body.read(response_env.body)
          unless response_body
            Logging.warn(
              "Unable to read response body for #{Redaction.url(request_url)}; " \
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

        def parse_stream(response_env)
          parser.parse_stream(
            request_url: request_url,
            request_body: request_body,
            response_status: response_env.status,
            events: stream_events(response_env),
            response_headers: response_env.response_headers
          )
        end

        def stream_events(response_env)
          if stream_tap&.received?
            events = stream_tap.events
            return events unless stream_tap.overflowed? || stream_tap.failed?
          else
            body = Body.read(response_env.body)
            return Capture::SSE.parse(body) if body.present?
          end

          Logging.warn(capture_warning)
          []
        end

        def capture_warning
          suffix = "recording usage_source=#{Usage::Source::UNKNOWN}. " \
                   "Use LlmCostTracker.track_stream for manual capture."
          label = Redaction.url(request_url)
          return "Unable to capture streaming response for #{label}; #{suffix}" unless stream_tap&.overflowed?

          "Streaming response for #{label} exceeded #{Capture::SSE::LIMIT_BYTES} bytes; #{suffix}"
        end
      end
    end
  end
end
