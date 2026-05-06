# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"
require "active_support/core_ext/string/inflections"

require_relative "../logging"
require_relative "../timing"
require_relative "../capture/stream_collector"
require_relative "../capture/stream_tracker"

module LlmCostTracker
  module Integrations
    module Base
      Result = Data.define(:name, :status, :message)

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
        name = integration_name
        problems = version_problems + target_problems
        if problems.any?
          return Result.new(name, :warn, "#{name} integration cannot be installed: #{problems.join('; ')}")
        end

        installed = patch_targets.reject { |target| target.fetch(:optional) }.all? do |target|
          target.fetch(:constant_name).to_s.safe_constantize&.ancestors&.include?(target.fetch(:patch))
        end
        return Result.new(name, :ok, "#{name} integration installed") if installed

        Result.new(name, :warn, "#{name} integration is enabled but not installed")
      end

      def elapsed_ms(started_at)
        Timing.elapsed_ms(started_at)
      end

      def enforce_budget!
        LlmCostTracker::Tracker.enforce_budget! if active?
      end

      def record_safely
        yield
      rescue LlmCostTracker::Error
        raise
      rescue StandardError => e
        Logging.warn("#{integration_name} integration failed to record usage: #{e.class}: #{e.message}")
      end

      def request_params(args, kwargs)
        params = args.first.is_a?(Hash) ? args.first : {}
        params.merge(kwargs).with_indifferent_access
      end

      def track_stream(stream, collector:)
        return stream unless active?

        LlmCostTracker::Capture::StreamTracker.new(
          stream: stream,
          collector: collector,
          active: -> { active? },
          finish: ->(errored:) { record_safely { collector.finish!(errored: errored) } }
        ).wrap
      end

      def stream_collector(request)
        LlmCostTracker::Capture::StreamCollector.new(
          provider: integration_name.to_s,
          model: request[:model]
        )
      end

      def object_value(object, *keys)
        keys.each do |key|
          value = read_object_value(object, key)
          return value unless value.nil?
        end
        nil
      end

      def object_dig(object, *path)
        path.reduce(object) do |current, key|
          return nil if current.nil?

          read_object_value(current, key)
        end
      end

      def minimum_version = nil

      def version_constant = nil

      def patch_targets = []

      def patch_target(constant_name, with:, methods:, optional: false)
        {
          constant_name: constant_name,
          patch: with,
          method_names: Array(methods),
          optional: optional
        }
      end

      module_function :object_value, :object_dig

      private

      def read_object_value(object, key)
        return nil if object.nil?

        if object.is_a?(Hash)
          return object[key] if object.key?(key)
          return object[key.name] if key.is_a?(Symbol) && object.key?(key.name)
        end

        object.public_send(key) if object.respond_to?(key)
      end

      module_function :read_object_value
      private_class_method :read_object_value

      def validate_contract!
        problems = version_problems + target_problems
        return if problems.empty?

        raise Error, "#{integration_name} integration cannot be installed: #{problems.join('; ')}"
      end

      def version_problems
        return [] unless minimum_version

        name = integration_name.to_s
        version = Gem.loaded_specs[integration_name.to_s]&.version || constant_version
        return ["#{name} >= #{minimum_version} is required, but #{name} is not loaded"] unless version
        return [] if version >= Gem::Version.new(minimum_version)

        ["#{name} >= #{minimum_version} is required, detected #{version}"]
      end

      def constant_version
        return nil unless version_constant

        value = version_constant.to_s.safe_constantize
        value ? Gem::Version.new(value.to_s) : nil
      rescue ArgumentError
        nil
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
