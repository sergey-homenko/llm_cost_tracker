# frozen_string_literal: true

module LlmCostTracker
  module Integrations
    module RubyLlm
      module V2
        class Frame
          STACK = :llm_cost_tracker_ruby_llm_frames

          attr_reader :payload, :provider, :workflow

          class << self
            def current = stack.last

            def open(payload, compaction: false, workflow: nil)
              new(payload, compaction, workflow).tap { |frame| stack << frame }
            end

            def close(payload)
              index = stack.rindex { |frame| frame.payload.equal?(payload) }
              index ? stack.slice!(index..) : []
            end

            def discard(frame) = stack.delete_if { |open| open.equal?(frame) }

            private

            def stack = Thread.current[STACK] ||= []
          end

          def initialize(payload, compaction, workflow)
            @payload = payload
            @compaction = compaction
            @workflow = workflow
            @reported = []
          end

          def observe(seam, value, provider)
            @provider = provider
            case seam
            when :parse_completion_body then @raw = value unless value.is_a?(Hash)
            when :build_chunk then (@window ||= Attempt.stream_window).push(value)
            else @response = value
            end
          end

          def request_started
            @request_started_at = Timing.now_monotonic
            @latency_ms = nil
          end

          def request_finished(payload)
            @latency_ms = Timing.elapsed_ms(@request_started_at) if @request_started_at
            @workflow = payload.slice(:workflow_id, :workflow_name, :workflow_step_name)
          end

          def add_attempt(usage)
            raw = @raw unless usage[:status] == :succeeded && usage[:tokens].to_h.empty?
            @reported << [usage, { latency_ms: @latency_ms, events: @window&.events, raw: raw }]
            @window = nil
            @raw = nil if raw
          end

          def attempts
            final = @reported.rindex { |usage, _| usage[:status] == :succeeded } || (@reported.size - 1 if @response)
            payload = @compaction ? @payload.except(:provider_options) : @payload
            @reported.each_with_index.map do |(usage, reported), index|
              Attempt.new(usage, payload, final: index == final, response: @response, provider: @provider, **reported)
            end
          end
        end
      end
    end
  end
end
