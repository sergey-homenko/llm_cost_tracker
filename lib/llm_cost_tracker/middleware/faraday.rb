# frozen_string_literal: true

require "faraday"

require_relative "faraday/exchange"

module LlmCostTracker
  module Middleware
    class Faraday < ::Faraday::Middleware
      def initialize(app, **options)
        super(app)
        @tags = options.fetch(:tags, {})
      end

      def call(request_env)
        return @app.call(request_env) unless LlmCostTracker.configuration.enabled

        Exchange.new(request_env, tags: @tags).call(@app)
      end
    end
  end
end
