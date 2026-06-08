# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"
require "active_support/core_ext/string/inflections"

require_relative "../check"
require_relative "../logging"
require_relative "../timing"
require_relative "../capture/stream_collector"
require_relative "../capture/stream_tracker"

module LlmCostTracker
  module Integrations
    module Base
      def integration_name
        @integration_name ||= name.demodulize.underscore.to_sym
      end

      def provider(value = nil)
        @provider = value.to_s if value
        @provider ||= integration_name.to_s
      end

      def active?
        LlmCostTracker.configuration.instrumented?(integration_name)
      end

      def install
        validate_contract!
        patch_targets.each do |target|
          target_class = target.fetch(:constant_name).to_s.safe_constantize
          install_patch(target_class, target.fetch(:patch)) if target_class
        end
      end

      def status
        name = integration_name.to_s
        problems = version_problems + target_problems
        if problems.any?
          return Check.new(:warn, name, "#{name} integration cannot be installed: #{problems.join('; ')}")
        end

        installed = patch_targets.reject { |target| target.fetch(:optional) }.all? do |target|
          target.fetch(:constant_name).to_s.safe_constantize&.ancestors&.include?(target.fetch(:patch))
        end
        return Check.new(:ok, name, "#{name} integration installed") if installed

        Check.new(:warn, name, "#{name} integration is enabled but not installed")
      end

      def enforce_budget!(request:, provider: self.provider)
        return unless active?

        LlmCostTracker::Budget.enforce!(
          provider: provider,
          model: request[:model],
          request: request
        )
      end

      def record_safely
        yield
      rescue LlmCostTracker::Error
        raise
      rescue StandardError => e
        Logging.warn("#{integration_name} integration failed to record usage: #{e.class}: #{e.message}")
      end

      def request_params(args, kwargs)
        params =
          case args.first
          when Hash then args.first
          when nil then {}
          else args.first.to_h
          end
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

      def track_stream(stream, collector:)
        return stream unless active?

        LlmCostTracker::Capture::StreamTracker.new(
          stream: stream,
          collector: collector,
          active: -> { active? },
          finish: ->(errored) { record_safely { collector.finish!(errored: errored) } }
        ).wrap
      end

      def stream_collector(request, provider: self.provider)
        LlmCostTracker::Capture::StreamCollector.new(
          provider: provider,
          model: request[:model],
          pricing_mode: stream_pricing_mode(request),
          request: request
        )
      end

      def stream_pricing_mode(_request)
        nil
      end

      def minimum_version(value = nil)
        @minimum_version = value if value
        @minimum_version
      end

      def gem_version
        Gem.loaded_specs[integration_name.to_s]&.version
      end

      def patch_targets = []

      def patch_target(constant_name, with:, optional: false, skip_when_methods_missing: false)
        {
          constant_name: constant_name,
          patch: with,
          method_names: with.instance_methods,
          optional: optional,
          skip_when_methods_missing: skip_when_methods_missing
        }
      end

      private

      def validate_contract!
        problems = version_problems + target_problems
        return if problems.empty?

        raise Error, "#{integration_name} integration cannot be installed: #{problems.join('; ')}"
      end

      def version_problems
        return [] unless minimum_version

        name = integration_name.to_s
        version = gem_version
        return ["#{name} >= #{minimum_version} is required, but #{name} is not loaded"] unless version
        return [] if version >= Gem::Version.new(minimum_version)

        ["#{name} >= #{minimum_version} is required, detected #{version}"]
      end

      def target_problems
        patch_targets.flat_map do |target|
          constant_name = target.fetch(:constant_name)
          target_class = constant_name.to_s.safe_constantize
          next [] if target_class.nil? && target.fetch(:optional)
          next ["#{constant_name} is not loaded"] unless target_class

          missing_methods(target_class, target)
        end
      end

      def missing_methods(target_class, target)
        return [] if target[:skip_when_methods_missing]

        target.fetch(:method_names).filter_map do |method_name|
          next if target_class.method_defined?(method_name) || target_class.private_method_defined?(method_name)

          "#{target.fetch(:constant_name)}##{method_name} is not available"
        end
      end

      def install_patch(target, patch)
        return if target&.ancestors&.include?(patch)

        target.prepend(patch)
      end
    end
  end
end
