# frozen_string_literal: true

require "json"

module LlmCostTracker
  module Parsers
    module SSE
      DONE_MARKER = "[DONE]"

      class << self
        def parse(body)
          return [] if body.nil? || body.empty?

          return parse_json_array(body) if probably_json_array?(body)

          parse_event_stream(body)
        end

        private

        def parse_event_stream(body)
          events = []
          current_event = nil
          data_lines = []

          body.each_line do |raw|
            line = raw.chomp

            if line.empty?
              events << finalize_event(current_event, data_lines) if data_lines.any?
              current_event = nil
              data_lines = []
              next
            end

            next if line.start_with?(":")

            field, _, value = line.partition(":")
            value = value[1..] if value.start_with?(" ")

            case field
            when "event" then current_event = value
            when "data"  then data_lines << value
            end
          end

          events << finalize_event(current_event, data_lines) if data_lines.any?
          events.compact
        end

        def parse_json_array(body)
          parsed = JSON.parse(body)
          return [] unless parsed.is_a?(Array)

          parsed.map { |entry| { event: nil, data: entry } }
        rescue JSON::ParserError
          []
        end

        def finalize_event(event_name, data_lines)
          payload = data_lines.join("\n")
          return nil if payload == DONE_MARKER

          { event: event_name, data: decode_data(payload) }
        end

        def decode_data(payload)
          return payload if payload.empty?

          JSON.parse(payload)
        rescue JSON::ParserError
          payload
        end

        def probably_json_array?(body)
          body.lstrip.start_with?("[")
        end
      end
    end
  end
end
