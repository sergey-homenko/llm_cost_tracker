# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"
require "active_support/core_ext/string/inflections"

require_relative "../check"
require_relative "../logging"
require_relative "../timing"
require_relative "../capture/stream_collector"
require_relative "../capture/stream_tracker"
require_relative "base/patch_target"

module LlmCostTracker
  module Integrations
    module Base
      def integration_name
        @integration_name ||= name.demodulize.underscore.to_sym
      end

      def provider = integration_name.to_s

      def active?
        LlmCostTracker.configuration.enabled && LlmCostTracker.configuration.instrumented?(integration_name)
      end

      def minimum_version(value = nil)
        @minimum_version = value if value
        @minimum_version
      end

      def maximum_version(value = nil)
        @maximum_version = value if value
        @maximum_version
      end

      def gem_version
        Gem.loaded_specs[integration_name.to_s]&.version
      end

      def patch_targets = []

      def patch_target(constant_name, with:, optional: false, skip_when_methods_missing: false)
        PatchTarget.new(constant_name:, patch: with, optional:, skip_when_methods_missing:)
      end

      def install
        validate_contract!
        Logging.warn(untested_version_message) if untested_version?
        patch_targets.each(&:install)
      end

      def status
        name = integration_name.to_s
        violation = contract_violation
        return Check.new(:warn, name, violation) if violation
        return Check.new(:warn, name, untested_version_message) if untested_version?
        return Check.new(:warn, name, "#{name} integration is enabled but not installed") unless installed?

        missing = patch_targets.reject(&:target_class).map(&:constant_name).uniq
        return Check.new(:ok, name, "#{name} integration installed") if missing.empty?

        Check.new(
          :warn,
          name,
          "#{name} integration installed without #{missing.join(', ')}; their calls are not recorded"
        )
      end

      def enforce_budget!(request:, provider: self.provider, tags: nil)
        return unless active?

        LlmCostTracker::Budget.enforce!(
          provider: provider,
          model: request[:model],
          request: request,
          tags: tags
        )
      end

      def record_safely
        yield
      rescue *LlmCostTracker::CALLER_ERRORS
        raise
      rescue StandardError => e
        Logging.warn("#{integration_name} integration failed to record usage: #{e.class}: #{e.message}")
      end

      def record_passthrough(provider:,
                             model:,
                             response:,
                             latency_ms:,
                             service_line_items: [],
                             usage_source: LlmCostTracker::Usage::Source::SDK_RESPONSE,
                             pricing_mode: nil,
                             **token_attributes)
        return unless active?

        record_safely do
          LlmCostTracker::Tracker.record(
            event: LlmCostTracker::Event.build(
              provider: provider,
              model: model,
              token_usage: LlmCostTracker::Usage::TokenUsage.build(**token_attributes),
              usage_source: usage_source,
              pricing_mode: pricing_mode,
              provider_response_id: provider_response_id_for(response),
              service_line_items: service_line_items
            ),
            latency_ms: latency_ms
          )
        end
      end

      def record_once(event, **)
        LlmCostTracker::Tracker.record(event: event.keyed_by_response_id, **)
      rescue ActiveRecord::RecordNotUnique
        nil
      end

      def provider_response_id_for(response) = (response.id if response.respond_to?(:id))

      def client_host(client)
        URI.parse(client.base_url.to_s).host if client
      rescue URI::InvalidURIError
        nil
      end

      def request_params(args, kwargs)
        params = args.first
        params = params.to_h unless params.is_a?(Hash)
        params.merge(kwargs).with_indifferent_access
      rescue StandardError
        kwargs.to_h.with_indifferent_access
      end

      def wrap_blocking(args, kwargs, record:, provider: self.provider)
        request = request_params(args, kwargs)
        enforce_budget!(request: request, provider: provider)
        started_at = LlmCostTracker::Timing.now_monotonic
        response = yield
        record_safely { record.call(response, request, LlmCostTracker::Timing.elapsed_ms(started_at)) }
        response
      end

      def wrap_stream(args, kwargs, collector:, provider: self.provider)
        request = request_params(args, kwargs)
        enforce_budget!(request: request, provider: provider)
        built = collector.call(request)
        stream = yield(built)
        track_stream(stream, collector: built)
      end

      def stream_collector(request, pricing_mode: nil)
        LlmCostTracker::Capture::StreamCollector.new(
          provider: provider,
          model: request[:model],
          pricing_mode: pricing_mode,
          request: request
        )
      end

      private

      def track_stream(stream, collector:)
        return stream unless active?

        LlmCostTracker::Capture::StreamTracker.new(
          stream: stream,
          collector: collector,
          active: -> { active? },
          finish: ->(errored) { record_safely { collector.finish!(errored: errored) } }
        ).wrap
      end

      def validate_contract!
        violation = contract_violation
        raise Error, violation if violation
      end

      def contract_violation
        problems = version_problems + target_problems
        "#{integration_name} integration cannot be installed: #{problems.join('; ')}" if problems.any?
      end

      def version_problems
        return [] unless minimum_version

        name = integration_name.to_s
        version = gem_version
        return ["#{name} >= #{minimum_version} is required, but #{name} is not loaded"] unless version
        return [] if version >= Gem::Version.new(minimum_version)

        ["#{name} >= #{minimum_version} is required, detected #{version}"]
      end

      def untested_version?
        maximum_version && gem_version && gem_version >= Gem::Version.new(maximum_version)
      end

      def untested_version_message
        "#{integration_name} #{gem_version} is newer than the tested range (< #{maximum_version}); " \
          "its calls may not be recorded"
      end

      def target_problems = patch_targets.flat_map(&:problems)

      def installed? = patch_targets.reject(&:optional).all?(&:installed?)
    end
  end
end
