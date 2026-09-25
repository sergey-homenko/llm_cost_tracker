# frozen_string_literal: true

require_relative "event_window"
require_relative "sse"

module LlmCostTracker
  module Capture
    class StreamTap
      MAX_PENDING_BYTES = 16 * 1_048_576

      def initialize(notable: nil)
        @window = EventWindow.new(notable: notable)
        @reader = SSE::Reader.new { |event| @window.push(event[:data], type: event[:event]) }
        @received = false
        @failed = false
      end

      def <<(chunk)
        return if @failed

        @received = true
        @reader << chunk
        fail! if @reader.pending_bytesize > MAX_PENDING_BYTES
      rescue StandardError
        fail!
      end

      def received?
        @received
      end

      def failed?
        @failed
      end

      def overflowed?
        @window.overflowed?
      end

      def events
        @reader&.finish
        @failed ? [] : @window.events
      rescue StandardError
        fail!
        []
      end

      private

      def fail!
        @failed = true
        @reader = nil
        @window = EventWindow.new
      end
    end
  end
end
