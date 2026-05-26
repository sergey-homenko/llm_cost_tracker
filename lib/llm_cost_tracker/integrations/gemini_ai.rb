# frozen_string_literal: true

require_relative "base"

module LlmCostTracker
  module Integrations
    module GeminiAi
      extend Base

      class << self
        def integration_name
          :gemini_ai
        end

        def enforce_budget!(request:)
          return unless active?

          LlmCostTracker::Budget.enforce!(
            provider: "gemini",
            model: request[:model],
            request: request
          )
        end

        def minimum_version
          "4.0.0"
        end

        # gemini-ai exposes Gemini::GEM[:version], not Gemini::VERSION,
        # so base.rb's default constant_version can't find it.
        def constant_version
          gem_hash = "Gemini::GEM".safe_constantize
          return nil unless gem_hash.is_a?(Hash)

          Gem::Version.new(gem_hash[:version].to_s)
        rescue ArgumentError
          nil
        end

        def patch_targets
          [patch_target("Gemini::Controllers::Client", with: ClientPatch)]
        end

        def record_response(response, path:, payload:, base_address:, latency_ms:)
          return unless active?
          return unless response.is_a?(Hash)

          record_safely do
            url = "#{base_address}/#{path}"
            event = LlmCostTracker::Parsers.find_for_provider("gemini")&.parse(
              request_url: url,
              request_body: payload&.to_json,
              response_status: 200,
              response_body: response.to_json
            )
            next unless event

            LlmCostTracker::Tracker.record(event: event, latency_ms: latency_ms)
          end
        end

        def record_stream_response(stream_events, path:, payload:, base_address:, latency_ms:)
          return unless active?
          return unless stream_events.is_a?(Array)

          record_safely do
            url = "#{base_address}/#{path}"
            # stream_events is an array of parsed JSON hashes (the :event field from each SSE chunk).
            # Wrap them in the {data: hash} shape that parse_stream / find_event_value expects.
            events = stream_events.map { |chunk| { data: chunk } }
            event = LlmCostTracker::Parsers.find_for_provider("gemini")&.parse_stream(
              request_url: url,
              request_body: payload&.to_json,
              response_status: 200,
              events: events
            )
            next unless event

            LlmCostTracker::Tracker.record(event: event, latency_ms: latency_ms)
          end
        end
      end

      module ClientPatch
        def request(path, payload, server_sent_events: nil, request_method: "POST", &callback)
          addr = @model_address.to_s
          bare_model = addr.include?("/models/") ? addr.split("/models/").last : nil
          request_hash = (payload || {}).merge(model: bare_model)
          LlmCostTracker::Integrations::GeminiAi.enforce_budget!(request: request_hash)

          sse = server_sent_events.nil? ? @server_sent_events : server_sent_events

          # For non-SSE generateContent calls, record the blocking response.
          if path.to_s.end_with?(":generateContent") && !sse
            started_at = LlmCostTracker::Timing.now_monotonic
            response = super

            LlmCostTracker::Integrations::GeminiAi.record_response(
              response,
              path: path,
              payload: payload,
              base_address: @base_address,
              latency_ms: LlmCostTracker::Timing.elapsed_ms(started_at)
            )

            return response
          end

          # For SSE calls (generateContent or streamGenerateContent), the gem collects
          # all chunks synchronously and returns an array of parsed event hashes.
          # Record usage from the accumulated stream after super returns.
          if sse
            started_at = LlmCostTracker::Timing.now_monotonic
            stream_events = super

            LlmCostTracker::Integrations::GeminiAi.record_stream_response(
              stream_events,
              path: path,
              payload: payload,
              base_address: @base_address,
              latency_ms: LlmCostTracker::Timing.elapsed_ms(started_at)
            )

            return stream_events
          end

          super
        end
      end
    end
  end
end
