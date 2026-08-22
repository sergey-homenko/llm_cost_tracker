# frozen_string_literal: true

require "active_support/core_ext/module/delegation"
require "active_support/core_ext/string/inflections"

require_relative "mutability"

module LlmCostTracker
  class Configuration
    class Section
      include Mutability

      class << self
        def attributes(*names)
          names.each do |name|
            attr_reader name

            define_method(:"#{name}=") do |value|
              ensure_mutable!
              instance_variable_set(:"@#{name}", value)
            end
          end
        end

        def enum_attribute(name, allowed:, default:)
          attr_reader name

          define_method(:"#{name}=") do |value|
            ensure_mutable!
            instance_variable_set(:"@#{name}", normalize_enum(name, value, allowed, default))
          end
        end
      end

      attr_reader :owner
      private :owner

      delegate :finalized?, to: :owner

      def initialize(owner)
        @owner = owner
      end

      def finalize!; end

      private

      def section_name
        self.class.name.split("::").last.underscore
      end

      def normalize_enum(name, value, allowed, default)
        value = default if value.nil?
        return value if allowed.include?(value)

        raise Error, "Unknown #{section_name}.#{name}: #{value.inspect}. Use one of: #{allowed.join(', ')}"
      end
    end
  end
end
