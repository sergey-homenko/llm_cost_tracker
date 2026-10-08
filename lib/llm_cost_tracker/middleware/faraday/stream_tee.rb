# frozen_string_literal: true

require "faraday"

require_relative "../../capture/stream_tap"

module LlmCostTracker
  module Middleware
    class Faraday < ::Faraday::Middleware
      module StreamTee
        class << self
          def install(env, parser)
            request = env.request
            return nil unless request

            original = request.on_data
            return nil unless original

            tap = Capture::StreamTap.new(notable: parser.method(:retain_stream_event?),
                                         trim: parser.method(:trim_stream_event))
            request.on_data = proc do |chunk, size, chunk_env|
              tap << chunk
              forward(original, chunk, size, chunk_env)
            end
            tap
          rescue StandardError => e
            Logging.warn("Unable to install streaming tap: #{e.class}: #{e.message}")
            nil
          end

          private

          def forward(callable, chunk, size, env)
            arity = callable.arity
            return callable.call(chunk, size, env) if arity.negative?

            case arity
            when 0, 1 then callable.call(chunk)
            when 2 then callable.call(chunk, size)
            else callable.call(chunk, size, env)
            end
          end
        end
      end
    end
  end
end
