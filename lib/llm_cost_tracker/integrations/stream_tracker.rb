# frozen_string_literal: true

require "monitor"

require_relative "../logging"
require_relative "../stream_collector"
require_relative "../value_helpers"
require_relative "object_reader"

module LlmCostTracker
  module Integrations
    class StreamTracker
      def self.wrap(stream, collector:, active:, finish: nil) = new(stream, collector, active, finish).wrap

      def initialize(stream, collector, active, finish)
        @stream = stream
        @collector = collector
        @active = active
        @finish = finish || proc { |errored:| @collector.finish!(errored: errored) }
        @finished = false
        @capture_failed = false
        @monitor = Monitor.new
      end

      def wrap
        return @stream unless @stream

        iterator_wrapped = @stream.instance_variable_defined?(:@iterator) && wrap_iterator?
        wrap_each if !iterator_wrapped && @stream.respond_to?(:each)

        @stream
      rescue StandardError => e
        Logging.warn("stream integration failed to install wrapper: #{e.class}: #{e.message}")
        @stream
      end

      private

      def wrap_iterator?
        iterator = @stream.instance_variable_get(:@iterator)
        return false unless iterator.respond_to?(:each)

        @stream.instance_variable_set(:@iterator, tracked_iterator(iterator))
        true
      end

      def wrap_each
        tracker = self
        original_each = @stream.method(:each)
        @stream.define_singleton_method(:each) do |&block|
          next enum_for(:each) unless block

          tracker.__send__(:each_from, original_each, &block)
        end
      end

      def tracked_iterator(iterator)
        Enumerator.new do |yielder|
          each_from(iterator) { |event| yielder << event }
        end
      end

      def each_from(iterable)
        errored = false
        iterate(iterable) do |event|
          capture(event)
          yield event
        end
      rescue StandardError
        errored = true
        raise
      ensure
        finish!(errored: errored)
      end

      def iterate(iterable, &)
        if iterable.respond_to?(:each)
          iterable.each(&)
        else
          iterable.call(&)
        end
      end

      def capture(event)
        payload = normalize(event_payload(event))
        @collector.event(payload, type: event_type(event, payload))
      rescue StandardError => e
        warn_capture_failure(e)
      end

      def event_payload(event)
        if event.respond_to?(:deep_to_h)
          event.deep_to_h
        elsif event.respond_to?(:to_h)
          event.to_h
        else
          event_attributes(event)
        end
      end

      def event_attributes(event)
        %i[type id model usage response message].each_with_object({}) do |key, attributes|
          value = ObjectReader.read(event, key)
          attributes[key] = value unless value.nil?
        end
      end

      def event_type(event, payload)
        value = ObjectReader.first(event, :type) || payload["type"]
        value&.to_s
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
          converted = object_hash(value)
          converted ? normalize(converted) : ValueHelpers.deep_dup(value)
        end
      end

      def object_hash(value)
        if value.respond_to?(:deep_to_h)
          value.deep_to_h
        elsif value.respond_to?(:to_h)
          value.to_h
        end
      rescue StandardError
        nil
      end

      def warn_capture_failure(error)
        should_warn = @monitor.synchronize do
          next false if @capture_failed

          @capture_failed = true
          true
        end
        return unless should_warn

        Logging.warn("stream integration failed to capture event: #{error.class}: #{error.message}")
      end

      def finish!(errored:)
        should_finish = @monitor.synchronize do
          next false if @finished

          @finished = true
          true
        end
        return unless should_finish && @active.call

        @finish.call(errored: errored)
      end
    end
  end
end
