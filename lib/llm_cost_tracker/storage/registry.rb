# frozen_string_literal: true

require "monitor"

require_relative "../errors"

module LlmCostTracker
  module Storage
    VerificationResult = Data.define(:status, :name, :message)

    module Registry
      MUTEX = Monitor.new

      class << self
        def register(name, backend)
          name = normalize_name(name)
          validate_backend!(backend)
          MUTEX.synchronize { @backends = backends.merge(name => backend).freeze }
          backend
        end

        def fetch(name)
          key = normalize_name(name)
          backends.fetch(key) do
            raise Error, "Unknown storage_backend: #{key.inspect}. Use one of: #{names.join(', ')}"
          end
        end

        def registered?(name)
          backends.key?(normalize_name(name))
        end

        def names
          backends.keys
        end

        private

        def backends
          @backends || MUTEX.synchronize { @backends ||= {}.freeze }
        end

        def normalize_name(name)
          name.to_sym
        end

        def validate_backend!(backend)
          return if backend.respond_to?(:save)

          raise ArgumentError, "storage backend must respond to save"
        end
      end
    end

    def self.register(name, backend)
      Registry.register(name, backend)
    end

    def self.backends
      Registry.names
    end
  end
end
