# frozen_string_literal: true

require_relative "sse"

module LlmCostTracker
  module Capture
    class EventWindow
      HEAD_EVENTS = 16
      TAIL_EVENTS = 32
      HEAVY_STRING_BYTES = 8 * 1024
      IGNORED_PAYLOAD_KEYS = %w[b64_json partial_image_b64 snapshot logprobs].freeze

      def initialize(notable: nil)
        @notable = notable
        @head = []
        @kept = []
        @tail = []
        @bytes = 0
        @overflowed = false
      end

      def push(data, type: nil)
        # The openai gem's chat stream helper resends all logprobs so far in logprobs.* events; none carry usage.
        return if @overflowed || type&.start_with?("logprobs.")

        event = { event: type, data: strip_heavy_payload(data) }
        size = approximate_bytesize(event)
        if @head.size < HEAD_EVENTS
          @head << [event, size]
        else
          @tail << [event, size]
          settle(@tail.shift) if @tail.size > TAIL_EVENTS
        end
        @bytes += size
        overflow! if @bytes > SSE::LIMIT_BYTES
      rescue TypeError, SystemStackError
        overflow!
      end

      def events
        (@head + @kept + @tail).map(&:first)
      end

      def overflowed?
        @overflowed
      end

      private

      def settle(entry)
        return @kept << entry if notable?(entry.first[:data])

        @bytes -= entry.last
      end

      def notable?(data)
        @notable&.call(data)
      rescue StandardError
        false
      end

      def overflow!
        @overflowed = true
        @head = []
        @kept = []
        @tail = []
      end

      def strip_heavy_payload(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested), out|
            next if IGNORED_PAYLOAD_KEYS.include?(key.to_s)

            out[key] = strip_heavy_payload(nested)
          end
        when Array
          value.map { |nested| strip_heavy_payload(nested) }
        when String
          value.bytesize > HEAVY_STRING_BYTES ? "" : value
        else
          value
        end
      end

      def approximate_bytesize(value)
        case value
        when Hash
          value.sum { |key, nested| approximate_bytesize(key) + approximate_bytesize(nested) + 4 }
        when Array
          value.sum { |nested| approximate_bytesize(nested) + 2 }
        when Numeric, true, false, nil
          8
        else
          value.to_s.bytesize + 2
        end
      end
    end
  end
end
