# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module LlmCostTracker
  module Integrations
    module Base
      PatchTarget = Data.define(:constant_name, :patch, :optional, :skip_when_methods_missing) do
        def target_class = constant_name.to_s.safe_constantize

        def installed? = target_class&.ancestors&.include?(patch)

        def install
          target = target_class
          target.prepend(patch) unless target.nil? || target.ancestors.include?(patch)
        end

        def problems
          target = target_class
          return [] if target.nil? && optional
          return ["#{constant_name} is not loaded"] unless target
          return [] if skip_when_methods_missing

          patch.instance_methods.filter_map do |method_name|
            next if target.method_defined?(method_name) || target.private_method_defined?(method_name)

            "#{constant_name}##{method_name} is not available"
          end
        end
      end
    end
  end
end
