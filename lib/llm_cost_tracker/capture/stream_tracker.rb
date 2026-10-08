# frozen_string_literal: true

module LlmCostTracker
  module Capture
    class StreamTracker
      def initialize(stream:, collector:, active:, finish: nil)
        @stream = stream
        @collector = collector
        @active = active
        @finish = finish || proc { |errored| collector.finish!(errored: errored) }
        @finished = false
        @capture_failed = false
        @mutex = Mutex.new
      end

      def wrap
        return @stream unless @stream

        iterator = @stream.instance_variable_get(:@iterator)
        if iterator.respond_to?(:each)
          wrap_iterator(iterator)
        elsif @stream.respond_to?(:each)
          wrap_each
        else
          Logging.warn(
            "stream integration found no wrappable iterator on #{@stream.class} " \
            "(missing both `@iterator` ivar and `#each`); usage will not be captured"
          )
        end

        @stream
      rescue StandardError => e
        Logging.warn("stream integration failed to install wrapper: #{e.class}: #{e.message}")
        @stream
      end

      private

      def wrap_iterator(iterator)
        relayed = Enumerator.new { |yielder| relay(iterator.method(:each)) { |event| yielder << event } }
        @stream.instance_variable_set(:@iterator, relayed)
      end

      def wrap_each
        original_each = @stream.method(:each)
        relayed_each = ->(&block) { relay(original_each, &block) }
        @stream.define_singleton_method(:each) do |&block|
          next enum_for(:each) unless block

          relayed_each.call(&block)
        end
      end

      def relay(source)
        errored = false
        source.call do |event|
          capture(event)
          yield event
        end
      rescue Exception # rubocop:disable Lint/RescueException
        errored = true
        raise
      ensure
        finish!(errored: errored)
      end

      def capture(event)
        data = event.to_h if event.respond_to?(:to_h)
        type = event.type if event.respond_to?(:type)
        @collector.event(data || {}, type: type&.to_s)
      rescue StandardError => e
        warn_capture_failure(e)
      end

      def warn_capture_failure(error)
        first_failure = @mutex.synchronize { !@capture_failed && (@capture_failed = true) }
        Logging.warn("stream integration failed to capture event: #{error.class}: #{error.message}") if first_failure
      end

      def finish!(errored:)
        claimed = @mutex.synchronize { !@finished && (@finished = true) }
        return unless claimed && @active.call

        begin
          @finish.call(errored)
        rescue StandardError
          @mutex.synchronize { @finished = false }
          raise
        end
      end
    end
  end
end
