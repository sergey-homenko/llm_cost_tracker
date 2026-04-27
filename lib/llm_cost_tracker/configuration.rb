# frozen_string_literal: true

require_relative "errors"
require_relative "value_helpers"
require_relative "configuration/instrumentation"

module LlmCostTracker
  class Configuration
    include ConfigurationInstrumentation

    OPENAI_COMPATIBLE_PROVIDERS = { "openrouter.ai" => "openrouter", "api.deepseek.com" => "deepseek" }.freeze

    BUDGET_EXCEEDED_BEHAVIORS = %i[notify raise block_requests].freeze
    STORAGE_ERROR_BEHAVIORS = %i[ignore warn raise].freeze
    STORAGE_BACKENDS = %i[log active_record custom].freeze
    UNKNOWN_PRICING_BEHAVIORS = %i[ignore warn raise].freeze
    SHARED_SCALAR_ATTRIBUTES = %i[enabled custom_storage on_budget_exceeded monthly_budget daily_budget per_call_budget
                                  log_level prices_file max_tag_count max_tag_value_bytesize].freeze
    SHARED_ENUM_ATTRIBUTES = {
      storage_backend: [STORAGE_BACKENDS, :log],
      budget_exceeded_behavior: [BUDGET_EXCEEDED_BEHAVIORS, :notify],
      storage_error_behavior: [STORAGE_ERROR_BEHAVIORS, :warn],
      unknown_pricing_behavior: [UNKNOWN_PRICING_BEHAVIORS, :warn]
    }.freeze
    DEFAULT_REDACTED_TAG_KEYS = %w[api_key access_token authorization credential password refresh_token secret].freeze

    attr_reader(
      *SHARED_SCALAR_ATTRIBUTES,
      :budget_exceeded_behavior,
      :default_tags,
      :pricing_overrides,
      :instrumented_integrations,
      :report_tag_breakdowns,
      :redacted_tag_keys,
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
      @daily_budget       = nil
      @per_call_budget    = nil
      self.budget_exceeded_behavior = :notify
      self.storage_error_behavior = :warn
      self.unknown_pricing_behavior = :warn
      @log_level          = :info
      @prices_file        = nil
      @max_tag_count      = 50
      @max_tag_value_bytesize = 1024
      @pricing_overrides = {}
      @instrumented_integrations = []
      @report_tag_breakdowns = []
      @redacted_tag_keys = DEFAULT_REDACTED_TAG_KEYS.dup
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

    def redacted_tag_keys=(value)
      ensure_shared_configuration_mutable!
      @redacted_tag_keys = Array(value).map(&:to_s)
    end

    SHARED_SCALAR_ATTRIBUTES.each do |name|
      define_method("#{name}=") do |value|
        ensure_shared_configuration_mutable!
        instance_variable_set(:"@#{name}", value)
      end
    end

    SHARED_ENUM_ATTRIBUTES.each do |name, (allowed, default)|
      define_method("#{name}=") do |value|
        ensure_shared_configuration_mutable!
        instance_variable_set(:"@#{name}", normalize_enum(name, value, allowed, default: default))
      end
    end

    def finalize!
      @default_tags = ValueHelpers.deep_freeze(@default_tags || {})
      @pricing_overrides = ValueHelpers.deep_freeze(@pricing_overrides || {})
      @instrumented_integrations = ValueHelpers.deep_freeze(@instrumented_integrations || [])
      @report_tag_breakdowns = ValueHelpers.deep_freeze(Array(@report_tag_breakdowns))
      @redacted_tag_keys = ValueHelpers.deep_freeze(Array(@redacted_tag_keys))
      @openai_compatible_providers = ValueHelpers.deep_freeze(@openai_compatible_providers || {})
      @finalized = true
      self
    end

    def finalized? = @finalized

    def dup_for_configuration
      copy = dup
      copy.instance_variable_set(:@default_tags, ValueHelpers.deep_dup(@default_tags || {}))
      copy.instance_variable_set(:@pricing_overrides, ValueHelpers.deep_dup(@pricing_overrides || {}))
      copy.instance_variable_set(
        :@instrumented_integrations,
        ValueHelpers.deep_dup(@instrumented_integrations || [])
      )
      copy.instance_variable_set(:@report_tag_breakdowns, ValueHelpers.deep_dup(@report_tag_breakdowns || []))
      copy.instance_variable_set(:@redacted_tag_keys, ValueHelpers.deep_dup(@redacted_tag_keys || []))
      copy.instance_variable_set(
        :@openai_compatible_providers,
        ValueHelpers.deep_dup(@openai_compatible_providers || {})
      )
      copy.instance_variable_set(:@finalized, false)
      copy
    end

    def active_record? = storage_backend == :active_record

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
