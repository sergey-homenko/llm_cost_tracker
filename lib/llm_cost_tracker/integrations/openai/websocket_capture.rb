# frozen_string_literal: true

require "English"

module LlmCostTracker
  module Integrations
    module Openai
      class WebsocketCapture
        TRACKED_EVENTS = %w[response.created error response.completed response.incomplete response.failed].freeze
        private_constant :TRACKED_EVENTS

        def initialize(url)
          @url = url
          @lanes = {}
          @tags_by_response = {}
          @deferred = nil
        end

        def sending(event)
          request = budget_checked_create(event)
          yield.tap { (@lanes[request["stream_id"]] ||= [nil]) << Tags::Context.tags if request }
        end

        def reading
          yield
        ensure
          raise_deferred unless $ERROR_INFO
        end

        def track(event)
          type = (event.type if event.respond_to?(:type)).to_s
          return unless Openai.active? && TRACKED_EVENTS.include?(type)

          Openai.record_safely { route(type, Capture::SdkPayload.normalize(event)) }
        rescue BudgetExceededError, UnknownPricingError => e
          @deferred ||= e
        end

        def raise_deferred
          error = @deferred
          @deferred = nil
          raise error if error
        end

        private

        def budget_checked_create(event)
          return unless Openai.active?

          request = Capture::SdkPayload.normalize(event)
          return unless request.is_a?(Hash) && request["type"] == "response.create"

          Openai.enforce_budget!(request: request.with_indifferent_access, provider: Openai.provider_for_host(url_host))
          request
        end

        def route(type, data)
          response = data["response"].to_h
          case type
          when "response.created" then @tags_by_response[response["id"]] = advance_lane(data["stream_id"])
          when "error" then advance_lane(data["stream_id"])
          else record(response)
          end
        end

        def advance_lane(stream_id)
          lane = @lanes[stream_id]
          lane.shift if lane && lane.size > 1
          lane&.first
        end

        def record(response)
          tags = @tags_by_response.delete(response["id"])
          host = url_host
          event = Providers::Openai::ResponseParser.event_from_response(
            response: response,
            request: { "tools" => response["tools"] },
            provider: Openai.provider_for_host(host),
            host: host,
            usage_source: Usage::Source::STREAM_FINAL
          )
          Tracker.record(event: event.with(stream: true), context_tags: tags) if event
        end

        def url_host = URI(@url.to_s).host
      end
    end
  end
end
