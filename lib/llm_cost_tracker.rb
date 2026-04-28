# frozen_string_literal: true

require "active_support"
require "active_support/notifications"
require "monitor"

require_relative "llm_cost_tracker/version"
require_relative "llm_cost_tracker/configuration"
require_relative "llm_cost_tracker/errors"
require_relative "llm_cost_tracker/logging"
require_relative "llm_cost_tracker/parameter_hash"
require_relative "llm_cost_tracker/cost"
require_relative "llm_cost_tracker/usage_breakdown"
require_relative "llm_cost_tracker/event"
require_relative "llm_cost_tracker/parsed_usage"
require_relative "llm_cost_tracker/price_registry"
require_relative "llm_cost_tracker/price_sync"
require_relative "llm_cost_tracker/pricing"
require_relative "llm_cost_tracker/parsers/base"
require_relative "llm_cost_tracker/parsers/openai_usage"
require_relative "llm_cost_tracker/parsers/openai"
require_relative "llm_cost_tracker/parsers/openai_compatible"
require_relative "llm_cost_tracker/parsers/anthropic"
require_relative "llm_cost_tracker/parsers/gemini"
require_relative "llm_cost_tracker/parsers/sse"
require_relative "llm_cost_tracker/parsers/registry"
require_relative "llm_cost_tracker/middleware/faraday"
require_relative "llm_cost_tracker/integrations/registry"
require_relative "llm_cost_tracker/budget"
require_relative "llm_cost_tracker/unknown_pricing"
require_relative "llm_cost_tracker/event_metadata"
require_relative "llm_cost_tracker/tag_context"
require_relative "llm_cost_tracker/tag_sanitizer"
require_relative "llm_cost_tracker/tags_column"
require_relative "llm_cost_tracker/tag_key"
require_relative "llm_cost_tracker/tag_sql"
require_relative "llm_cost_tracker/tag_query"
require_relative "llm_cost_tracker/tag_accessors"
require_relative "llm_cost_tracker/llm_api_call_metrics"
require_relative "llm_cost_tracker/tracker"
require_relative "llm_cost_tracker/retention"
require_relative "llm_cost_tracker/report_data"
require_relative "llm_cost_tracker/report_formatter"
require_relative "llm_cost_tracker/report"
require_relative "llm_cost_tracker/doctor"
require_relative "llm_cost_tracker/capture_verifier"

module LlmCostTracker
  CONFIGURATION_MUTEX = Monitor.new

  class << self
    def configuration
      CONFIGURATION_MUTEX.synchronize { @configuration ||= Configuration.new }
    end

    def configure
      config = CONFIGURATION_MUTEX.synchronize do
        current = @configuration || Configuration.new
        current = current.dup_for_configuration if current.finalized?
        @configuration = current
        yield(current)
        current.openai_compatible_providers = current.openai_compatible_providers.dup
        current.finalize!
        current
      end
      Integrations.install!
      warn_for_configuration!(config)
    end

    def reset_configuration!
      CONFIGURATION_MUTEX.synchronize { @configuration = Configuration.new }
      UnknownPricing.reset! if defined?(UnknownPricing)
      Storage::ActiveRecordStore.reset! if defined?(Storage::ActiveRecordStore)
      TagContext.clear! if defined?(TagContext)
    end

    def enforce_budget!
      Tracker.enforce_budget!
    end

    def with_tags(tags = nil, **kwargs, &)
      merged = (tags || {}).to_h.merge(kwargs)
      TagContext.with(merged, &)
    end

    def track(provider:, input_tokens:, output_tokens:, model: nil, latency_ms: nil, stream: false,
              usage_source: :manual, enforce_budget: false, provider_response_id: nil, pricing_mode: nil, **metadata)
      enforce_budget! if enforce_budget
      Tracker.record(
        provider: provider.to_s,
        model: model,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        latency_ms: latency_ms,
        stream: stream,
        usage_source: usage_source,
        provider_response_id: provider_response_id,
        pricing_mode: pricing_mode,
        metadata: metadata
      )
    end

    def track_stream(provider:, model: nil, latency_ms: nil, enforce_budget: false, provider_response_id: nil,
                     pricing_mode: nil, **metadata)
      require_relative "llm_cost_tracker/stream_collector"
      enforce_budget! if enforce_budget
      collector = StreamCollector.new(
        provider: provider.to_s,
        model: model,
        latency_ms: latency_ms,
        provider_response_id: provider_response_id,
        pricing_mode: pricing_mode,
        metadata: metadata
      )
      yield collector
      collector.finish!
    rescue StandardError
      collector&.finish!(errored: true)
      raise
    end

    private

    def warn_for_configuration!(config = configuration)
      return unless config.budget_exceeded_behavior == :block_requests
      return if config.active_record?

      Logging.warn(
        ":block_requests requires storage_backend = :active_record for monthly and daily preflight; " \
        "preflight blocking will be skipped."
      )
    end
  end
end

require_relative "llm_cost_tracker/railtie" if defined?(Rails::Railtie)

if defined?(Faraday)
  Faraday::Middleware.register_middleware(
    llm_cost_tracker: LlmCostTracker::Middleware::Faraday
  )
end
