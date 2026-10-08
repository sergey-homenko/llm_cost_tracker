# frozen_string_literal: true

module LlmCostTracker
  module Integrations
    module Anthropic
      class BatchResultsCapture
        include Enumerable

        def initialize(raw_stream)
          @raw_stream = raw_stream
        end

        def each(&block)
          return enum_for(:each) unless block

          deferred = nil
          @raw_stream.each do |response|
            begin
              Integrations::Anthropic.record_batch_result(response)
            rescue BudgetExceededError, UnknownPricingError => e
              deferred ||= e
            end
            block.call(response)
          end
          raise deferred if deferred
        end

        def respond_to_missing?(name, include_private = false)
          @raw_stream.respond_to?(name, include_private) || super
        end

        def method_missing(name, ...)
          return super unless @raw_stream.respond_to?(name)

          @raw_stream.public_send(name, ...)
        end
      end
    end
  end
end
