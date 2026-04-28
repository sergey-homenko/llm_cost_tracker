# frozen_string_literal: true

module LlmCostTracker
  module ConfigurationStorageBackend
    def storage_backend=(value)
      ensure_shared_configuration_mutable!
      @storage_backend = normalize_storage_backend(value)
    end

    private

    def normalize_storage_backend(value)
      value = :log if value.nil?
      value = value.to_sym
      return value if self.class::STORAGE_BACKENDS.include?(value)
      return value if defined?(Storage::Registry) && Storage::Registry.registered?(value)

      names = if defined?(Storage::Registry)
                Storage::Registry.names
              else
                self.class::STORAGE_BACKENDS
              end
      raise Error, "Unknown storage_backend: #{value.inspect}. Use one of: #{names.join(', ')}"
    end
  end
end
