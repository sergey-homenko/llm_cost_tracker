# frozen_string_literal: true

require "faraday"

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

        @app.call(request_env).on_complete do |response_env|
          process(request_url, request_body, response_env)
        end
      rescue StandardError => e
        # Never break the actual request — log and re-raise
        raise e
      end

      private

      def process(request_url, request_body, response_env)
        parser = Parsers::Registry.find_for(request_url)
        return unless parser

        parsed = parser.parse(
          request_url,
          request_body,
          response_env.status,
          read_body(response_env.body)
        )
        return unless parsed

        Tracker.record(
          provider: parsed[:provider],
          model: parsed[:model],
          input_tokens: parsed[:input_tokens],
          output_tokens: parsed[:output_tokens],
          metadata: @tags.merge(parsed.except(:provider, :model, :input_tokens, :output_tokens, :total_tokens))
        )
      rescue StandardError => e
        warn "[LlmCostTracker] Error processing response: #{e.message}" if LlmCostTracker.configuration.log_level == :debug
      end

      def read_body(body)
        case body
        when String then body
        when nil then ""
        else body.to_s
        end
      end
    end
  end
end
