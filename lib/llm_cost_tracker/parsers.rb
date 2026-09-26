# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "json"
require "uri"

require_relative "providers"

module LlmCostTracker
  module Parsers
    PARSER_PROVIDERS = %i[Openai Azure OpenaiCompatible Anthropic Gemini].freeze

    def self.find_for(url)
      instances.find { |parser| parser.class.match?(url) }
    end

    def self.find_for_provider(provider)
      provider_name = provider.to_s.downcase
      instances.find { |parser| parser.class.provider_names.include?(provider_name) }
    end

    def self.instances
      @instances ||= PARSER_PROVIDERS.map { |name| Providers.const_get(name)::Parser.new }.freeze
    end
    private_class_method :instances

    module UrlMatchers
      def uri_matches?(url)
        uri = parsed_uri(url)
        uri ? yield(uri) : false
      end

      def parsed_uri(url)
        URI.parse(url.to_s)
      rescue URI::InvalidURIError
        nil
      end
    end

    class Base
      extend UrlMatchers
      include UrlMatchers

      class << self
        def match?(_url)
          raise NotImplementedError
        end

        def provider_names
          []
        end
      end

      def parse(**)
        raise NotImplementedError
      end

      def streaming_request?(_request_url, request_parsed)
        request_parsed["stream"] == true
      end

      def model_for(_request_url, request_parsed)
        request_parsed["model"]
      end

      def parse_stream(**)
        nil
      end

      def retain_stream_event?(_data)
        false
      end

      def auto_enable_stream_usage?(_request_url, _request_parsed)
        false
      end

      def safe_json_parse(body)
        return {} if body.blank?

        parsed = JSON.parse(body)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      private

      def each_event_data(events, reverse: false)
        enumerator = reverse ? events.reverse_each : events.each

        enumerator.each do |event|
          data = event[:data]
          yield data if data.is_a?(Hash)
        end
      end

      def find_event_value(events, reverse: false)
        each_event_data(events, reverse:) do |data|
          value = yield(data)
          return value if value.present?
        end

        nil
      end

      def build_unknown_stream_usage(provider:,
                                     model:,
                                     provider_response_id:,
                                     pricing_mode: nil,
                                     service_line_items: nil)
        Event.build(
          provider: provider,
          provider_response_id: provider_response_id,
          pricing_mode: pricing_mode,
          model: model || Event::UNKNOWN_MODEL,
          token_usage: Usage::TokenUsage.build(input_tokens: 0, output_tokens: 0, total_tokens: 0),
          stream: true,
          usage_source: Usage::Source::UNKNOWN,
          service_line_items: service_line_items
        )
      end
    end
  end
end
