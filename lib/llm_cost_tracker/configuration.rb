# frozen_string_literal: true

require_relative "errors"

module LlmCostTracker
  class Configuration
    # Hostname => provider name for OpenAI-compatible APIs.
    OPENAI_COMPATIBLE_PROVIDERS = {
      "openrouter.ai" => "openrouter",
      "api.deepseek.com" => "deepseek"
    }.freeze

    BUDGET_EXCEEDED_BEHAVIORS = %i[notify raise block_requests].freeze
    STORAGE_ERROR_BEHAVIORS = %i[ignore warn raise].freeze
    STORAGE_BACKENDS = %i[log active_record custom].freeze
    UNKNOWN_PRICING_BEHAVIORS = %i[ignore warn raise].freeze

    attr_accessor :enabled,
                  :custom_storage,     # callable object for :custom backend
                  :default_tags,       # Hash of default tags added to every event
                  :on_budget_exceeded, # callable, receives event hash
                  :monthly_budget,     # Float, in USD — nil means no limit
                  :log_level,          # :debug, :info, :warn
                  :prices_file,        # JSON/YAML file that overrides built-in prices
                  :pricing_overrides   # Hash to override built-in pricing

    attr_reader :budget_exceeded_behavior, # :notify, :raise, :block_requests
                :storage_backend, # :log, :active_record, :custom
                :storage_error_behavior, # :ignore, :warn, :raise
                :unknown_pricing_behavior, # :ignore, :warn, :raise
                :openai_compatible_providers

    def initialize
      @enabled = true
      self.storage_backend = :log
      @custom_storage     = nil
      @default_tags       = {}
      @on_budget_exceeded = nil
      @monthly_budget     = nil
      self.budget_exceeded_behavior = :notify
      self.storage_error_behavior = :warn
      self.unknown_pricing_behavior = :warn
      @log_level          = :info
      @prices_file        = nil
      @pricing_overrides  = {}
      self.openai_compatible_providers = OPENAI_COMPATIBLE_PROVIDERS
    end

    def openai_compatible_providers=(providers)
      @openai_compatible_providers = normalize_openai_compatible_providers(providers)
    end

    def storage_backend=(value)
      @storage_backend = normalize_enum(:storage_backend, value, STORAGE_BACKENDS, default: :log)
    end

    def budget_exceeded_behavior=(value)
      @budget_exceeded_behavior = normalize_enum(
        :budget_exceeded_behavior,
        value,
        BUDGET_EXCEEDED_BEHAVIORS,
        default: :notify
      )
    end

    def storage_error_behavior=(value)
      @storage_error_behavior = normalize_enum(
        :storage_error_behavior,
        value,
        STORAGE_ERROR_BEHAVIORS,
        default: :warn
      )
    end

    def unknown_pricing_behavior=(value)
      @unknown_pricing_behavior = normalize_enum(
        :unknown_pricing_behavior,
        value,
        UNKNOWN_PRICING_BEHAVIORS,
        default: :warn
      )
    end

    def normalize_openai_compatible_providers!
      self.openai_compatible_providers = openai_compatible_providers
    end

    def active_record?
      storage_backend == :active_record
    end

    def log?
      storage_backend == :log
    end

    private

    def normalize_enum(name, value, allowed, default:)
      value = default if value.nil?
      value = value.to_sym
      return value if allowed.include?(value)

      raise Error, "Unknown #{name}: #{value.inspect}. Use one of: #{allowed.join(', ')}"
    end

    def normalize_openai_compatible_providers(providers)
      (providers || {}).each_with_object({}) do |(host, provider), normalized|
        normalized[host.to_s.downcase] = provider.to_s
      end
    end
  end
end
