# frozen_string_literal: true

module LlmCostTracker
  module Integrations
    module Anthropic
      module MessagesPatch
        def create(*args, **kwargs)
          Integrations::Anthropic.wrap_blocking(args, kwargs, **Integrations::Anthropic.blocking_seam(@client)) { super }
        end

        def stream(*args, **kwargs)
          Integrations::Anthropic.wrap_stream(args, kwargs, **Integrations::Anthropic.stream_seam(@client)) { super }
        end

        def stream_raw(*args, **kwargs)
          Integrations::Anthropic.wrap_stream(args, kwargs, **Integrations::Anthropic.stream_seam(@client)) { super }
        end
      end

      module FallbackMiddlewarePatch
        def call(req, nxt)
          return super if req.streaming? || !Integrations::Anthropic.active?

          hops = []
          response = super(req, ->(hop_req) { nxt.call(hop_req).tap { |hop| hops << [hop_req, hop] } })
          answered = hops.select { |_hop_req, hop| hop.status < 300 }
          answered[...-1].each { |hop| Integrations::Anthropic.record_refused_hop(*hop) }
          response
        end

        private

        def consume_hop(*args, **kwargs)
          refused = Thread.current[:llm_cost_tracker_refused_hop]
          Thread.current[:llm_cost_tracker_refused_hop] = nil
          Integrations::Anthropic.record_refused_stream_hop(refused) if refused && kwargs[:splice]
          super.tap { |hop| Thread.current[:llm_cost_tracker_refused_hop] = hop if hop[:refused] }
        end
      end

      module BatchesPatch
        def create(*args, **kwargs)
          Integrations::Anthropic.enforce_budget!(request: Integrations::Anthropic.request_params(args, kwargs))
          super
        end

        def results_streaming(*args, **kwargs)
          raw = super
          return raw unless Integrations::Anthropic.active?

          BatchResultsCapture.new(raw)
        end
      end
    end
  end
end
