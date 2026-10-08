# frozen_string_literal: true

require "faraday"
require "json"

require_relative "../../timing"
require_relative "body"
require_relative "response_reader"
require_relative "stream_tee"

module LlmCostTracker
  module Middleware
    class Faraday < ::Faraday::Middleware
      class Exchange
        def initialize(env, tags:)
          @env = env
          @tags = tags
          @url = env.url.to_s
          @parser = Parsers.find_for(@url)
          @body = Body.read(env.body) || Body.multipart_model_json(env, @parser)
          @request = @parser&.safe_json_parse(@body)
          @streaming = @parser&.streaming_request?(@url, @request)
        end

        def call(app)
          prepare_stream if @streaming
          if tracked?
            @context_tags, @metadata = tag_snapshot
            enforce_budget if post?
          end
          @request = nil
          perform(app, LlmCostTracker::Timing.now_monotonic)
        end

        private

        def prepare_stream
          @body = request_stream_usage || @body
          @stream_tap = StreamTee.install(@env, @parser)
        end

        def request_stream_usage
          return unless LlmCostTracker.configuration.capture.request_stream_usage
          return unless @parser.auto_enable_stream_usage?(@url, @request)

          options = @request["stream_options"]
          return if options.is_a?(Hash) && options.key?("include_usage")

          @request["stream_options"] = (options || {}).merge("include_usage" => true)
          @env.body = @request.to_json
        end

        def tracked?
          @parser || (post? && Parsers.batch_submission?(@env.url))
        end

        def post? = @env.method == :post

        def tag_snapshot
          [LlmCostTracker::Tags::Context.tags, resolved_tags]
        rescue StandardError => e
          Logging.warn("Error resolving request tags: #{e.class}: #{e.message}")
          [{}, {}]
        end

        def resolved_tags
          return @tags.to_h unless @tags.respond_to?(:call)

          (@tags.arity.zero? ? @tags.call : @tags.call(@env)).to_h
        end

        def enforce_budget
          Budget.enforce!(
            provider: @parser&.provider_for(@url),
            model: @parser&.model_for(@url, @request),
            request: @request,
            tags: Tracker.build_tags(context_tags: @context_tags, metadata: @metadata)
          )
        end

        def perform(app, started_at)
          received = false
          app.call(@env).on_complete do |response_env|
            received = true
            record_response(response_env, (LlmCostTracker::Timing.elapsed_ms(started_at) if post?))
          end
        rescue StandardError => e
          record_interruption(e, LlmCostTracker::Timing.elapsed_ms(started_at)) if @streaming && !received
          raise
        end

        def record_response(response_env, latency_ms)
          return unless @parser

          reader = ResponseReader.new(parser: @parser, request_url: @url, request_body: @body, stream_tap: @stream_tap)
          event = reader.call(response_env, streaming: @streaming)
          return unless event

          Tracker.record(event: event, latency_ms: latency_ms, metadata: @metadata, context_tags: @context_tags)
        rescue *LlmCostTracker::CALLER_ERRORS
          raise
        rescue ActiveRecord::RecordNotUnique
          nil
        rescue StandardError => e
          Logging.warn("Error processing response: #{e.class}: #{e.message}")
        end

        def record_interruption(error, latency_ms)
          Tracker.record(
            event: interrupted_event,
            latency_ms: latency_ms,
            metadata: interruption_metadata(error),
            context_tags: @context_tags
          )
        rescue LlmCostTracker::TransactionAbortedError
          raise
        rescue StandardError => e
          Logging.warn("Error recording interrupted stream: #{e.class}: #{e.message}")
        end

        def interrupted_event
          request = @parser.safe_json_parse(@body)
          Event.build(
            provider: @parser.provider_for(@url),
            model: @parser.model_for(@url, request) || Event::UNKNOWN_MODEL,
            token_usage: Usage::TokenUsage.build(input_tokens: 0, output_tokens: 0, total_tokens: 0),
            stream: true,
            usage_source: Usage::Source::UNKNOWN
          )
        end

        def interruption_metadata(error)
          metadata = (@metadata || {}).merge(stream_interrupted: true, stream_interrupted_error: error.class.name)
          status = error.response_status if error.respond_to?(:response_status)
          status ? metadata.merge(stream_interrupted_status: status) : metadata
        end
      end
    end
  end
end
