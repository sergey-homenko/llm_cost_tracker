# frozen_string_literal: true

require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/object/try"

require_relative "../logging"

module LlmCostTracker
  module Capture
    class StreamTracker
      def initialize(stream:, collector:, active:, finish: nil)
        @stream = stream
        @collector = collector
        @active = active
        @finish = finish || proc { |errored:| @collector.finish!(errored: errored) }
        @finished_ref = [false]
        @capture_failed = false
        @mutex = Mutex.new
      end

      def wrap
        return @stream unless @stream

        iterator_wrapped = false
        if @stream.instance_variable_defined?(:@iterator)
          iterator = @stream.instance_variable_get(:@iterator)
          if iterator.respond_to?(:each)
            @stream.instance_variable_set(:@iterator, Enumerator.new do |yielder|
              each_from(iterator) { |event| yielder << event }
            end)
            iterator_wrapped = true
          end
        end
        wrap_each if !iterator_wrapped && @stream.respond_to?(:each)

        register_orphan_finalizer
        @stream
      rescue StandardError => e
        Logging.warn("stream integration failed to install wrapper: #{e.class}: #{e.message}")
        @stream
      end

      private

      def wrap_each
        tracker = self
        original_each = @stream.method(:each)
        @stream.define_singleton_method(:each) do |&block|
          next enum_for(:each) unless block

          tracker.__send__(:each_from, original_each, &block)
        end
      end

      def each_from(iterable)
        errored = false
        if iterable.respond_to?(:each)
          iterable.each do |event|
            capture(event)
            yield event
          end
        else
          iterable.call do |event|
            capture(event)
            yield event
          end
        end
      rescue StandardError
        errored = true
        raise
      ensure
        finish!(errored: errored)
      end

      def capture(event)
        raw_payload = event.try(:deep_to_h) || event.try(:to_h)
        raw_payload ||= %i[type id model usage response message].each_with_object({}) do |key, attributes|
          value = event.try(key)
          attributes[key] = value unless value.nil?
        end
        payload = normalize(raw_payload)
        type = event.try(:type) || payload["type"]
        @collector.event(payload, type: type&.to_s)
      rescue StandardError => e
        warn_capture_failure(e)
      end

      def normalize(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested), normalized|
            normalized[key.to_s] = normalize(nested)
          end
        when Array
          value.map { |nested| normalize(nested) }
        when Symbol
          value.to_s
        when NilClass
          nil
        else
          converted = begin
            value.try(:deep_to_h) || value.try(:to_h)
          rescue StandardError
            nil
          end
          converted ? normalize(converted) : value.deep_dup
        end
      end

      def warn_capture_failure(error)
        should_warn = @mutex.synchronize do
          next false if @capture_failed

          @capture_failed = true
          true
        end
        return unless should_warn

        Logging.warn("stream integration failed to capture event: #{error.class}: #{error.message}")
      end

      def finish!(errored:)
        should_finish = @mutex.synchronize do
          next false if @finished_ref[0]

          @finished_ref[0] = true
          true
        end
        return unless should_finish && @active.call

        begin
          @finish.call(errored: errored)
        rescue StandardError
          @mutex.synchronize { @finished_ref[0] = false }
          raise
        end
      end

      def register_orphan_finalizer
        finished_ref = @finished_ref
        finish_proc = @finish
        active_proc = @active
        mutex = @mutex
        ObjectSpace.define_finalizer(@stream, lambda do |_object_id|
          mutex.synchronize do
            next if finished_ref[0]

            finished_ref[0] = true
          end
          next unless active_proc.call

          begin
            finish_proc.call(errored: false)
          rescue StandardError
            nil
          end
        end)
      rescue TypeError, ArgumentError
        nil
      end
    end
  end
end
