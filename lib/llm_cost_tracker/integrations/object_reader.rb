# frozen_string_literal: true

module LlmCostTracker
  module Integrations
    module ObjectReader
      module_function

      def first(object, *keys)
        keys.each do |key|
          value = read(object, key)
          return value unless value.nil?
        end
        nil
      end

      def nested(object, *path)
        path.reduce(object) do |current, key|
          return nil if current.nil?

          read(current, key)
        end
      end

      def read(object, key)
        return nil if object.nil?

        read_hash(object, key) || read_method(object, key) || read_index(object, key)
      end

      def integer(value)
        value.nil? ? 0 : value.to_i
      end

      def read_hash(object, key)
        return unless object.respond_to?(:key?)

        return object[key] if object.key?(key)

        string_key = key.to_s
        object[string_key] if object.key?(string_key)
      end

      def read_method(object, key)
        object.public_send(key) if object.respond_to?(key)
      end

      def read_index(object, key)
        return unless object.respond_to?(:[])

        object[key]
      rescue IndexError, NameError, TypeError
        nil
      end
    end
  end
end
