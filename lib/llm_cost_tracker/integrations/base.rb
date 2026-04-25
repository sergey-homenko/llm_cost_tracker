# frozen_string_literal: true

require_relative "../logging"
require_relative "object_reader"

module LlmCostTracker
  module Integrations
    module Base
      Result = Data.define(:name, :status, :message)

      def active?
        LlmCostTracker.configuration.instrumented?(integration_name)
      end

      def install
        target_patches.each { |target, patch| install_patch(target, patch) }
      end

      def status
        name = integration_name
        installed = target_patches.count { |target, patch| patch_installed?(target, patch) }
        available = target_patches.count { |target, _patch| target }
        return Result.new(name, :ok, "#{name} integration installed") if installed.positive?
        return Result.new(name, :warn, "#{name} SDK classes are not loaded") if available.zero?

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

      private

      def install_patch(target, patch)
        return unless target
        return if patch_installed?(target, patch)

        target.prepend(patch)
      end

      def patch_installed?(target, patch)
        target&.ancestors&.include?(patch)
      end
    end
  end
end
