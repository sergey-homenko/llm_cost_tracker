# frozen_string_literal: true

require "rails"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/try"

require_relative "llm_cost_tracker/version"
require_relative "llm_cost_tracker/configuration"
require_relative "llm_cost_tracker/errors"
require_relative "llm_cost_tracker/logging"
require_relative "llm_cost_tracker/tags/key"
require_relative "llm_cost_tracker/tags/context"
require_relative "llm_cost_tracker/tags/sanitizer"
require_relative "llm_cost_tracker/currency"
require_relative "llm_cost_tracker/usage/catalog"
require_relative "llm_cost_tracker/usage/token_usage"
require_relative "llm_cost_tracker/usage/source"
require_relative "llm_cost_tracker/pricing/rate"
require_relative "llm_cost_tracker/charges/cost"
require_relative "llm_cost_tracker/charges/line_item"
require_relative "llm_cost_tracker/charges/cost_status"
require_relative "llm_cost_tracker/event"
require_relative "llm_cost_tracker/pricing"
require_relative "llm_cost_tracker/parsers"
require_relative "llm_cost_tracker/middleware/faraday"
require_relative "llm_cost_tracker/integrations"
require_relative "llm_cost_tracker/budget"
require_relative "llm_cost_tracker/ledger"
require_relative "llm_cost_tracker/ingestion"
require_relative "llm_cost_tracker/tracker"

module LlmCostTracker
  require_relative "llm_cost_tracker/engine"
  autoload :Doctor, "llm_cost_tracker/doctor"
  autoload :CaptureVerifier, "llm_cost_tracker/capture_verifier"
  autoload :Report, "llm_cost_tracker/report"
  autoload :Retention, "llm_cost_tracker/retention"

  module Pricing
    autoload :Sync, "llm_cost_tracker/pricing/sync"
    autoload :Unknown, "llm_cost_tracker/pricing/unknown"
  end

  @configuration = Configuration.new

  class << self
    attr_reader :configuration

    def table_name_prefix
      "llm_cost_tracker_"
    end

    def configure
      config = configuration
      raise Error, "LlmCostTracker is already configured" if config.finalized?

      yield(config)
      config.finalize!
      Pricing::Registry.reset!
      Pricing::Registry.validate_file!(config.pricing.file)
      Integrations.install!
      config
    end

    def with_tags(tags = nil, **kwargs, &)
      Tags::Context.with((tags || {}).merge(kwargs), &)
    end

    def track(provider:,
              tokens:,
              model: nil,
              tags: {},
              latency_ms: nil,
              stream: false,
              usage_source: Usage::Source::MANUAL,
              enforce_budget: false,
              provider_response_id: nil,
              provider_project_id: nil,
              provider_api_key_id: nil,
              provider_workspace_id: nil,
              pricing_mode: nil,
              service_line_items: [])
      Tracker.record(
        event: Event.build(
          provider: provider,
          model: model,
          token_usage: Usage::TokenUsage.build_from_tokens(tokens),
          stream: stream,
          usage_source: usage_source,
          provider_response_id: provider_response_id,
          provider_project_id: provider_project_id,
          provider_api_key_id: provider_api_key_id,
          provider_workspace_id: provider_workspace_id,
          pricing_mode: pricing_mode,
          service_line_items: service_line_items
        ),
        latency_ms: latency_ms,
        metadata: tags,
        enforce_budget: enforce_budget
      )
    end

    def track_stream(provider:,
                     model: nil,
                     tags: {},
                     latency_ms: nil,
                     enforce_budget: false,
                     provider_response_id: nil,
                     provider_project_id: nil,
                     provider_api_key_id: nil,
                     provider_workspace_id: nil,
                     pricing_mode: nil)
      require_relative "llm_cost_tracker/capture/stream_collector"
      if enforce_budget
        Budget.enforce!(provider: provider,
                        model: model,
                        force: true,
                        tags: Tracker.build_tags(context_tags: nil, metadata: tags))
      end
      collector = Capture::StreamCollector.new(
        provider: provider.to_s,
        model: model,
        latency_ms: latency_ms,
        provider_response_id: provider_response_id,
        provider_project_id: provider_project_id,
        provider_api_key_id: provider_api_key_id,
        provider_workspace_id: provider_workspace_id,
        pricing_mode: pricing_mode,
        metadata: tags
      )
      begin
        yield collector
      rescue Exception # rubocop:disable Lint/RescueException -- record the spend and keep the caller's exception
        finish_errored_stream(collector)
        raise
      end
      collector.finish!
    end

    private

    def finish_errored_stream(collector)
      collector.finish!(errored: true)
    rescue LlmCostTracker::TransactionAbortedError
      raise
    rescue LlmCostTracker::BudgetExceededError, LlmCostTracker::UnknownPricingError => e
      Logging.warn("track_stream recorded the errored stream and did not raise #{e.class} over the block's " \
                   "exception: #{e.message}")
    rescue StandardError => e
      Logging.warn("track_stream could not record the errored stream: #{e.class}: #{e.message}")
    end
  end
end

require_relative "llm_cost_tracker/railtie"

Faraday::Middleware.register_middleware(
  llm_cost_tracker: LlmCostTracker::Middleware::Faraday
)

at_exit { LlmCostTracker::Ingestion::Worker.shutdown!(drain: false) if LlmCostTracker::Ingestion.async? }
