# frozen_string_literal: true

require_relative "errors"
require_relative "pricing/registry"
require_relative "tags/key"

module LlmCostTracker
  class Configuration
    OPENAI_COMPATIBLE_PROVIDERS = {
      "openrouter.ai" => "openrouter",
      "api.deepseek.com" => "deepseek",
      "api.groq.com" => "groq"
    }.freeze

    BUDGET_EXCEEDED_BEHAVIORS = %i[notify raise block_requests].freeze
    UNKNOWN_PRICING_BEHAVIORS = %i[ignore warn raise].freeze
    SHARED_SCALAR_ATTRIBUTES = %i[enabled default_tags on_budget_exceeded monthly_budget daily_budget per_call_budget
                                  log_level prices_file max_tag_count max_tag_value_bytesize].freeze
    SHARED_ENUM_ATTRIBUTES = {
      budget_exceeded_behavior: [BUDGET_EXCEEDED_BEHAVIORS, :notify],
      unknown_pricing_behavior: [UNKNOWN_PRICING_BEHAVIORS, :warn]
    }.freeze
    DEFAULT_REDACTED_TAG_KEYS = %w[api_key access_token authorization credential password refresh_token secret].freeze

    attr_reader(
      *SHARED_SCALAR_ATTRIBUTES,
      :budget_exceeded_behavior,
      :instrumented_integrations,
      :pricing_overrides,
      :report_tag_breakdowns,
      :redacted_tag_keys,
      :unknown_pricing_behavior,
      :openai_compatible_providers,
      :reconciliation_importers,
      :reconciliation_enabled,
      :auto_enable_stream_usage
    )

    def initialize
      @enabled = true
      @default_tags       = {}
      @on_budget_exceeded = nil
      @monthly_budget     = nil
      @daily_budget       = nil
      @per_call_budget    = nil
      self.budget_exceeded_behavior = :notify
      self.unknown_pricing_behavior = :warn
      @log_level          = :info
      @prices_file        = nil
      @max_tag_count      = 50
      @max_tag_value_bytesize = 1024
      self.pricing_overrides = {}
      @instrumented_integrations = Set.new
      @report_tag_breakdowns = []
      @redacted_tag_keys = DEFAULT_REDACTED_TAG_KEYS.dup
      self.openai_compatible_providers = OPENAI_COMPATIBLE_PROVIDERS
      @reconciliation_importers = {}
      @reconciliation_enabled = false
      @auto_enable_stream_usage = true
      @finalized = false
    end

    def reconciliation_enabled=(value)
      ensure_shared_configuration_mutable!
      @reconciliation_enabled = !!value
    end

    def auto_enable_stream_usage=(value)
      ensure_shared_configuration_mutable!
      @auto_enable_stream_usage = !!value
    end

    def reconciliation_importers=(importers)
      ensure_shared_configuration_mutable!
      raise Error, RECONCILIATION_DISABLED_MESSAGE unless @reconciliation_enabled

      @reconciliation_importers = (importers || {}).to_h do |source, importer|
        raise Error, "reconciliation_importers[#{source}] must respond to call" unless importer.respond_to?(:call)

        [source.to_sym, importer]
      end
    end

    def register_reconciliation_importer(source, &block)
      ensure_shared_configuration_mutable!
      raise Error, RECONCILIATION_DISABLED_MESSAGE unless @reconciliation_enabled
      raise Error, "register_reconciliation_importer requires a block" unless block

      @reconciliation_importers[source.to_sym] = block
    end

    RECONCILIATION_DISABLED_MESSAGE = "reconciliation is disabled; set config.reconciliation_enabled = true first"
    private_constant :RECONCILIATION_DISABLED_MESSAGE

    def openai_compatible_providers=(providers)
      ensure_shared_configuration_mutable!
      @openai_compatible_providers = normalize_openai_compatible_providers(providers)
    end

    def pricing_overrides=(value)
      ensure_shared_configuration_mutable!
      @pricing_overrides = Pricing::Registry.normalize_price_table(value || {})
    rescue ArgumentError => e
      raise Error, "invalid pricing_overrides: #{e.message}"
    end

    def report_tag_breakdowns=(value)
      ensure_shared_configuration_mutable!
      @report_tag_breakdowns = Array(value).map { |key| Tags::Key.validate!(key, error_class: Error) }
    end

    def redacted_tag_keys=(value)
      ensure_shared_configuration_mutable!
      @redacted_tag_keys = Array(value).map(&:to_s)
    end

    def instrument(*names)
      ensure_shared_configuration_mutable!
      @instrumented_integrations.merge(normalize_instrumentation_names(names))
    end

    def instrumented?(name)
      @instrumented_integrations.include?(name)
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
      @default_tags = deep_freeze(@default_tags || {})
      @pricing_overrides = deep_freeze(@pricing_overrides || {})
      @instrumented_integrations = deep_freeze(@instrumented_integrations || Set.new)
      @report_tag_breakdowns = deep_freeze(Array(@report_tag_breakdowns))
      @redacted_tag_keys = deep_freeze(Array(@redacted_tag_keys))
      @openai_compatible_providers = deep_freeze(
        normalize_openai_compatible_providers(@openai_compatible_providers)
      )
      @finalized = true
      self
    end

    def finalized?
      @finalized
    end

    private

    def normalize_enum(name, value, allowed, default:)
      value = default if value.nil?
      return value if allowed.include?(value)

      raise Error, "Unknown #{name}: #{value.inspect}. Use one of: #{allowed.join(', ')}"
    end

    def normalize_openai_compatible_providers(providers)
      (providers || {}).each_with_object({}) do |(host, provider), normalized|
        normalized[host.to_s.downcase] = provider.to_s
      end
    end

    def normalize_instrumentation_names(names)
      names = names.flatten
      integrations = Integrations.names
      return integrations if names == [:all]

      names.each do |name|
        next if integrations.include?(name)

        raise Error, "Unknown integration: #{name.inspect}. Use one of: #{integrations.join(', ')}"
      end
      names
    end

    def ensure_shared_configuration_mutable!
      return unless finalized?

      raise FrozenError, "can't modify frozen LlmCostTracker::Configuration"
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each do |key, nested_value|
          deep_freeze(key)
          deep_freeze(nested_value)
        end
        value.frozen? ? value : value.freeze
      when Array, Set
        value.each { |nested_value| deep_freeze(nested_value) }
        value.frozen? ? value : value.freeze
      when String
        value.frozen? ? value : value.freeze
      else
        value
      end
    end
  end
end
