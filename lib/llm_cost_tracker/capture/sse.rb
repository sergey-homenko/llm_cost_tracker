# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "json"

module LlmCostTracker
  module Capture
    module SSE
      DONE_MARKER = "[DONE]"
      LIMIT_BYTES = 1_048_576

      class << self
        def parse(body)
          events = []
          reader = Reader.new { |event| events << event }
          reader << body
          reader.finish
          events
        end
      end

      class Reader
        def initialize(&on_event)
          @on_event = on_event
          @pending = String.new(encoding: Encoding::BINARY)
          @mode = nil
          @event_name = nil
          @data_lines = []
          @scan_pos = 0
          @depth = 0
          @in_string = false
          @object_start = nil
        end

        def <<(chunk)
          @pending << chunk.to_s.b
          @mode ||= detect_mode
          case @mode
          when :sse then consume_lines
          when :array then consume_array
          end
        end

        def pending_bytesize
          @pending.bytesize
        end

        def finish
          return unless @mode == :sse

          consume_line(@pending) unless @pending.empty?
          @pending = String.new(encoding: Encoding::BINARY)
          dispatch
        end

        private

        def detect_mode
          first = @pending[/\S/]
          return nil unless first

          first == "[" ? :array : :sse
        end

        def consume_lines
          start = 0
          while (newline = @pending.index("\n", start))
            consume_line(@pending.byteslice(start, newline - start))
            start = newline + 1
          end
          @pending = @pending.byteslice(start..)
        end

        def consume_line(raw)
          line = raw.chomp("\r").force_encoding(Encoding::UTF_8)
          return dispatch if line.empty?
          return if line.start_with?(":")

          field, _, value = line.partition(":")
          value = value[1..] if value.start_with?(" ")
          case field
          when "event" then @event_name = value
          when "data" then @data_lines << value
          end
        end

        def dispatch
          emit(finalize_event(@event_name, @data_lines)) if @data_lines.any?
          @event_name = nil
          @data_lines = []
        end

        def finalize_event(event_name, data_lines)
          payload = data_lines.join("\n")
          return nil if payload == DONE_MARKER

          { event: event_name, data: decode_data(payload) }
        end

        def decode_data(payload)
          return payload if payload.blank?

          JSON.parse(payload)
        rescue JSON::ParserError
          payload
        end

        def consume_array
          pos = @scan_pos
          while (index = @pending.index(@in_string ? /["\\]/ : /[{}"]/, pos))
            pos = index + 1
            pos = advance_array(@pending.getbyte(index).chr, index, pos)
          end
          trim_array_buffer(pos)
        end

        def advance_array(char, index, pos)
          if @in_string
            return pos + 1 if char == "\\"

            @in_string = false
          elsif char == '"'
            @in_string = true
          elsif char == "{"
            @object_start = index if @depth.zero?
            @depth += 1
          elsif @depth.positive?
            @depth -= 1
            emit_object(index) if @depth.zero?
          end
          pos
        end

        def emit_object(end_index)
          text = @pending.byteslice(@object_start, end_index - @object_start + 1)
          @object_start = nil
          emit({ event: nil, data: JSON.parse(text.force_encoding(Encoding::UTF_8)) })
        rescue JSON::ParserError
          nil
        end

        def trim_array_buffer(pos)
          keep_from = @object_start || [pos, @pending.bytesize].min
          @pending = @pending.byteslice(keep_from..)
          @scan_pos = pos - keep_from
          @object_start &&= 0
        end

        def emit(event)
          @on_event.call(event) if event
        end
      end
    end
  end
end
