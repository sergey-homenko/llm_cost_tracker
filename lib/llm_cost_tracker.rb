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
require_relative "llm_cost_tracker/masking"
require_relative "llm_cost_tracker/token_usage"
require_relative "llm_cost_tracker/billing/components"
require_relative "llm_cost_tracker/billing/line_item"
require_relative "llm_cost_tracker/billing/cost_status"
require_relative "llm_cost_tracker/event"
require_relative "llm_cost_tracker/pricing"
require_relative "llm_cost_tracker/usage_capture"
require_relative "llm_cost_tracker/parsers"
require_relative "llm_cost_tracker/middleware/faraday"
require_relative "llm_cost_tracker/integrations"
require_relative "llm_cost_tracker/budget"
require_relative "llm_cost_tracker/pricing/unknown"
require_relative "llm_cost_tracker/ledger"
require_relative "llm_cost_tracker/ingestion"
require_relative "llm_cost_tracker/tracker"

module LlmCostTracker
  autoload :Reconciliation, "llm_cost_tracker/reconciliation"
  autoload :ReconcileTasks, "llm_cost_tracker/reconcile_tasks"
  autoload :Doctor,         "llm_cost_tracker/doctor"
  autoload :Report,         "llm_cost_tracker/report"
  autoload :Retention,      "llm_cost_tracker/retention"

  module Pricing
    autoload :Sync, "llm_cost_tracker/pricing/sync"
  end

  @configuration = Configuration.new

  class << self
    attr_reader :configuration

    def table_name_prefix
      "llm_cost_tracker_"
    end

    def reconciliation_enabled?
      configuration.reconciliation_enabled
    end

    def configure
      config = configuration
      raise Error, "LlmCostTracker is already configured" if config.finalized?

      yield(config)
      config.finalize!
      Pricing::Lookup.reset!
      Pricing::Registry.reset!
      Pricing::ServiceCharges.reset!
      Integrations.install!
      config
    end

    def reset_configuration!
      Ingestion::Worker.shutdown!(drain: false)
      @configuration = Configuration.new
      Pricing::Lookup.reset!
      Pricing::Registry.reset!
      Pricing::ServiceCharges.reset!
      Pricing::Unknown.reset!
      Ingestion::Worker.reset!
      Tags::Context.clear!
      Dashboard::SetupState.reset! if defined?(Dashboard::SetupState)
    end

    def with_tags(tags = nil, **kwargs, &)
      Tags::Context.with((tags || {}).merge(kwargs), &)
    end

    def track(provider:, tokens:, model: nil, tags: {}, latency_ms: nil, stream: false,
              usage_source: :manual, enforce_budget: false,
              provider_response_id: nil, provider_project_id: nil, provider_api_key_id: nil,
              provider_workspace_id: nil, batch: nil, pricing_mode: nil, service_line_items: [])
      Tracker.enforce_budget! if enforce_budget

      Tracker.record(
        capture: UsageCapture.build(
          provider: provider,
          model: model,
          token_usage: TokenUsage.build_from_tokens(tokens),
          stream: stream,
          usage_source: usage_source,
          provider_response_id: provider_response_id,
          provider_project_id: provider_project_id,
          provider_api_key_id: provider_api_key_id,
          provider_workspace_id: provider_workspace_id,
          batch: batch,
          pricing_mode: pricing_mode,
          service_line_items: service_line_items
        ),
        latency_ms: latency_ms,
        pricing_mode: pricing_mode,
        metadata: tags
      )
    end

    def track_stream(provider:, model: nil, tags: {}, latency_ms: nil, enforce_budget: false,
                     provider_response_id: nil, provider_project_id: nil, provider_api_key_id: nil,
                     provider_workspace_id: nil, batch: nil, pricing_mode: nil)
      require_relative "llm_cost_tracker/capture/stream_collector"
      Tracker.enforce_budget! if enforce_budget
      collector = Capture::StreamCollector.new(
        provider: provider.to_s,
        model: model,
        latency_ms: latency_ms,
        provider_response_id: provider_response_id,
        provider_project_id: provider_project_id,
        provider_api_key_id: provider_api_key_id,
        provider_workspace_id: provider_workspace_id,
        batch: batch,
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

at_exit { LlmCostTracker::Ingestion::Worker.shutdown!(drain: false) }
