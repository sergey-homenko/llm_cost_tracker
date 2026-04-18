# frozen_string_literal: true

module LlmCostTracker
  module ValueObject
    class << self
      def define(*members, &block)
        klass = data_class(*members)
        add_hash_like_readers(klass)
        klass.class_eval(&block) if block
        klass
      end

      private

      def data_class(*members)
        return Data.define(*members) if defined?(Data)

        Struct.new(*members, keyword_init: true) do
          def initialize(**kwargs)
            super
            freeze
          end
        end
      end

      def add_hash_like_readers(klass)
        klass.class_eval do
          def [](key)
            public_send(key.to_sym)
          end

          def dig(key, *rest)
            value = self[key]
            rest.empty? ? value : value&.dig(*rest)
          end

          def except(*keys)
            excluded = keys.map(&:to_sym)
            to_h.reject { |key, _value| excluded.include?(key.to_sym) }
          end
        end
      end
    end
  end
end
