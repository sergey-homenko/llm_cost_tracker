# frozen_string_literal: true

require_relative "errors"
require_relative "value_helpers"

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

    attr_accessor(
      :enabled,
      :custom_storage,
      :on_budget_exceeded,
      :monthly_budget,
      :log_level,
      :prices_file
    )

    attr_reader(
      :budget_exceeded_behavior,
      :default_tags,
      :pricing_overrides,
      :report_tag_breakdowns,
      :storage_backend,
      :storage_error_behavior,
      :unknown_pricing_behavior,
      :openai_compatible_providers
    )

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
      @report_tag_breakdowns = []
      self.openai_compatible_providers = OPENAI_COMPATIBLE_PROVIDERS
      @finalized = false
    end

    def default_tags=(value)
      ensure_shared_configuration_mutable!
      @default_tags = value
    end

    def openai_compatible_providers=(providers)
      ensure_shared_configuration_mutable!
      @openai_compatible_providers = normalize_openai_compatible_providers(providers)
    end

    def pricing_overrides=(value)
      ensure_shared_configuration_mutable!
      @pricing_overrides = value
    end

    def report_tag_breakdowns=(value)
      ensure_shared_configuration_mutable!
      @report_tag_breakdowns = value
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

    def finalize!
      @default_tags = ValueHelpers.deep_freeze(@default_tags || {})
      @pricing_overrides = ValueHelpers.deep_freeze(@pricing_overrides || {})
      @report_tag_breakdowns = ValueHelpers.deep_freeze(Array(@report_tag_breakdowns))
      @openai_compatible_providers = ValueHelpers.deep_freeze(@openai_compatible_providers || {})
      @finalized = true
      self
    end

    def finalized?
      @finalized
    end

    def dup_for_configuration
      copy = dup
      copy.instance_variable_set(:@default_tags, ValueHelpers.deep_dup(@default_tags || {}))
      copy.instance_variable_set(:@pricing_overrides, ValueHelpers.deep_dup(@pricing_overrides || {}))
      copy.instance_variable_set(:@report_tag_breakdowns, ValueHelpers.deep_dup(@report_tag_breakdowns || []))
      copy.instance_variable_set(:@openai_compatible_providers, ValueHelpers.deep_dup(@openai_compatible_providers || {}))
      copy.instance_variable_set(:@finalized, false)
      copy
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

    def ensure_shared_configuration_mutable!
      return unless finalized?

      raise FrozenError, "can't modify frozen LlmCostTracker::Configuration"
    end
  end
end
