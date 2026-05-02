# frozen_string_literal: true

require "rails"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/object/try"
require "active_support/core_ext/hash/indifferent_access"
require "active_support/core_ext/string/inflections"
require "active_support/notifications"

require_relative "llm_cost_tracker/version"
require_relative "llm_cost_tracker/configuration"
require_relative "llm_cost_tracker/errors"
require_relative "llm_cost_tracker/logging"
require_relative "llm_cost_tracker/tags/key"
require_relative "llm_cost_tracker/tags/context"
require_relative "llm_cost_tracker/tags/sanitizer"
require_relative "llm_cost_tracker/token_usage"
require_relative "llm_cost_tracker/billing/components"
require_relative "llm_cost_tracker/billing/service_charge"
require_relative "llm_cost_tracker/billing/cost_status"
require_relative "llm_cost_tracker/event"
require_relative "llm_cost_tracker/pricing"
require_relative "llm_cost_tracker/usage_capture"
require_relative "llm_cost_tracker/pricing/sync"
require_relative "llm_cost_tracker/parsers/base"
require_relative "llm_cost_tracker/parsers/openai_usage"
require_relative "llm_cost_tracker/parsers/openai"
require_relative "llm_cost_tracker/parsers/openai_compatible"
require_relative "llm_cost_tracker/parsers/anthropic"
require_relative "llm_cost_tracker/parsers/gemini"
require_relative "llm_cost_tracker/parsers/sse"
require_relative "llm_cost_tracker/parsers"
require_relative "llm_cost_tracker/middleware/faraday"
require_relative "llm_cost_tracker/integrations"
require_relative "llm_cost_tracker/budget"
require_relative "llm_cost_tracker/pricing/unknown"
require_relative "llm_cost_tracker/ledger"
require_relative "llm_cost_tracker/ingestion"
require_relative "llm_cost_tracker/tracker"
require_relative "llm_cost_tracker/retention"
require_relative "llm_cost_tracker/report"
require_relative "llm_cost_tracker/doctor"
require_relative "llm_cost_tracker/doctor/capture_verifier"

module LlmCostTracker
  @configuration = Configuration.new

  class << self
    attr_reader :configuration

    def configure
      config = configuration
      raise Error, "LlmCostTracker is already configured" if config.finalized?

      yield(config)
      config.openai_compatible_providers = config.openai_compatible_providers.dup
      config.finalize!
      Pricing::Lookup.reset!
      Integrations.install!
      config
    end

    def reset_configuration!
      Ingestion::Worker.shutdown!(drain: false)
      @configuration = Configuration.new
      Pricing::Lookup.reset!
      Pricing::Unknown.reset!
      Ingestion::Worker.reset!
      Tags::Context.clear!
    end

    def flush!(timeout: nil)
      if timeout
        Ingestion::Worker.flush!(timeout: timeout)
      else
        Ingestion::Worker.flush!
      end
    end

    def shutdown!(timeout: nil, drain: true)
      if timeout
        Ingestion::Worker.shutdown!(timeout: timeout, drain: drain)
      else
        Ingestion::Worker.shutdown!(drain: drain)
      end
    end

    def enforce_budget!
      Tracker.enforce_budget!
    end

    def with_tags(tags = nil, **kwargs, &)
      merged = (tags || {}).to_h.merge(kwargs)
      Tags::Context.with(merged, &)
    end

    def track(provider:, tokens:, model: nil, tags: {}, latency_ms: nil, stream: false,
              usage_source: :manual, enforce_budget: false,
              provider_response_id: nil, pricing_mode: nil, service_charges: [])
      enforce_budget! if enforce_budget

      Tracker.record(
        capture: UsageCapture.build(
          provider: provider,
          model: model,
          token_usage: TokenUsage.build_from_tokens(tokens),
          stream: stream,
          usage_source: usage_source,
          provider_response_id: provider_response_id,
          service_charges: service_charges
        ),
        latency_ms: latency_ms,
        pricing_mode: pricing_mode,
        metadata: tags
      )
    end

    def track_stream(provider:, model: nil, tags: {}, latency_ms: nil, enforce_budget: false,
                     provider_response_id: nil, pricing_mode: nil)
      require_relative "llm_cost_tracker/capture/stream_collector"
      enforce_budget! if enforce_budget
      collector = Capture::StreamCollector.new(
        provider: provider.to_s,
        model: model,
        latency_ms: latency_ms,
        provider_response_id: provider_response_id,
        pricing_mode: pricing_mode,
        metadata: tags
      )
      yield collector
      collector.finish!
    rescue StandardError
      collector&.finish!(errored: true)
      raise
    end
  end
end

require_relative "llm_cost_tracker/railtie"

Faraday::Middleware.register_middleware(
  llm_cost_tracker: LlmCostTracker::Middleware::Faraday
)

at_exit { LlmCostTracker.shutdown!(drain: false) }
