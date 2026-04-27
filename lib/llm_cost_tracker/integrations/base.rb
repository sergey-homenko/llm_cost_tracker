# frozen_string_literal: true

require_relative "../logging"
require_relative "object_reader"

module LlmCostTracker
  module Integrations
    module Base
      PatchTarget = Data.define(:constant_name, :patch, :method_names, :optional)
      Result = Data.define(:name, :status, :message)

      def active?
        LlmCostTracker.configuration.instrumented?(integration_name)
      end

      def install
        validate_contract!
        patch_targets.each do |target|
          target_class = constant(target.constant_name)
          install_patch(target_class, target.patch) if target_class
        end
      end

      def status
        name = integration_name
        problems = contract_problems
        if problems.any?
          return Result.new(name, :warn, "#{name} integration cannot be installed: #{problems.join('; ')}")
        end

        required_targets = patch_targets.reject(&:optional)
        installed = required_targets.count { |target| patch_installed?(constant(target.constant_name), target.patch) }
        return Result.new(name, :ok, "#{name} integration installed") if installed == required_targets.count

        Result.new(name, :warn, "#{name} integration is enabled but not installed")
      end

      def elapsed_ms(started_at)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
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
        params.merge(kwargs)
      end

      def constant(path)
        path.to_s.split("::").reduce(Object) do |scope, const_name|
          return nil unless scope.const_defined?(const_name, false)

          scope.const_get(const_name, false)
        end
      end

      def minimum_version = nil

      def version_constant = nil

      def patch_targets = []

      def patch_target(constant_name, with:, methods:, optional: false)
        PatchTarget.new(constant_name, with, Array(methods), optional)
      end

      private

      def validate_contract!
        problems = contract_problems
        return if problems.empty?

        raise Error, "#{integration_name} integration cannot be installed: #{problems.join('; ')}"
      end

      def contract_problems
        version_problems + target_problems
      end

      def version_problems
        return [] unless minimum_version

        name = integration_name.to_s
        version = installed_version
        return ["#{name} >= #{minimum_version} is required, but #{name} is not loaded"] unless version
        return [] if version >= Gem::Version.new(minimum_version)

        ["#{name} >= #{minimum_version} is required, detected #{version}"]
      end

      def installed_version
        Gem.loaded_specs[integration_name.to_s]&.version || constant_version
      end

      def constant_version
        return nil unless version_constant

        value = constant(version_constant)
        value ? Gem::Version.new(value.to_s) : nil
      rescue ArgumentError
        nil
      end

      def target_problems
        patch_targets.flat_map do |target|
          target_class = constant(target.constant_name)
          next [] if target_class.nil? && target.optional
          next ["#{target.constant_name} is not loaded"] unless target_class

          missing_methods(target_class, target)
        end
      end

      def missing_methods(target_class, target)
        target.method_names.filter_map do |method_name|
          next if target_class.method_defined?(method_name) || target_class.private_method_defined?(method_name)

          "#{target.constant_name}##{method_name} is not available"
        end
      end

      def install_patch(target, patch)
        return if patch_installed?(target, patch)

        target.prepend(patch)
      end

      def patch_installed?(target, patch)
        target&.ancestors&.include?(patch)
      end
    end
  end
end
