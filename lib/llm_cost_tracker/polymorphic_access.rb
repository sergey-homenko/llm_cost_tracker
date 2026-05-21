# frozen_string_literal: true

module LlmCostTracker
  module PolymorphicAccess
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
  end
end
