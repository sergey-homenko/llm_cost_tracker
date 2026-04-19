# frozen_string_literal: true

require "faraday"
require "json"

require_relative "../logging"

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

        enforce_budget_before_request(request_url)
        started_at = monotonic_time

        @app.call(request_env).on_complete do |response_env|
          process(request_env, request_url, request_body, response_env, elapsed_ms(started_at))
        end
      end

      private

      def process(request_env, request_url, request_body, response_env, latency_ms)
        parser = Parsers::Registry.find_for(request_url)
        return unless parser

        parsed = parse_response(parser, request_url, request_body, response_env)
        return unless parsed

        Tracker.record(
          provider: parsed.provider,
          model: parsed.model,
          input_tokens: parsed.input_tokens,
          output_tokens: parsed.output_tokens,
          latency_ms: latency_ms,
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
            "Unable to read response body for #{request_url}; streaming/SSE responses require manual tracking."
          )
          return nil
        end

        parser.parse(request_url, request_body, response_env.status, response_body)
      end

      def enforce_budget_before_request(request_url)
        return unless Parsers::Registry.find_for(request_url)

        Tracker.enforce_budget!
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
    end
  end
end
