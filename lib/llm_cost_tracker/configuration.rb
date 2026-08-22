# frozen_string_literal: true

require_relative "errors"
require_relative "deprecator"
require_relative "pricing/registry"
require_relative "tags/key"
require_relative "configuration/budgets"
require_relative "configuration/ingestion"
require_relative "configuration/pricing"
require_relative "configuration/tags"

module LlmCostTracker
  class Configuration
    include Mutability

    OPENAI_COMPATIBLE_PROVIDERS = {
      "openrouter.ai" => "openrouter",
      "api.deepseek.com" => "deepseek",
      "api.groq.com" => "groq"
    }.freeze

    SECTIONS = { budgets: Budgets, ingestion: Ingestion, pricing: Pricing, tags: Tags }.freeze

    SCALAR_ATTRIBUTES = %i[enabled auto_enable_stream_usage cache_rollups].freeze

    LOG_LEVEL_DEPRECATION = "config.log_level is deprecated and has no effect; " \
                            "LlmCostTracker logs through Rails.logger, which owns the level"

    DEPRECATED_ATTRIBUTES = {
      monthly_budget: %i[budgets monthly],
      daily_budget: %i[budgets daily],
      per_call_budget: %i[budgets per_call],
      budget_exceeded_behavior: %i[budgets exceeded_behavior],
      on_budget_exceeded: %i[budgets on_exceeded],
      default_tags: %i[tags default],
      max_tag_count: %i[tags max_count],
      max_tag_value_bytesize: %i[tags max_value_bytesize],
      redacted_tag_keys: %i[tags redacted_keys],
      report_tag_breakdowns: %i[tags breakdown_keys],
      prices_file: %i[pricing file],
      pricing_overrides: %i[pricing overrides],
      unknown_pricing_behavior: %i[pricing unknown_behavior],
      ingestion_pool_size: %i[ingestion pool_size]
    }.freeze

    DEPRECATED_WRITERS = { ingestion: %i[ingestion mode] }.freeze

    attr_reader(*SCALAR_ATTRIBUTES, *SECTIONS.keys, :instrumented_integrations, :openai_compatible_providers)

    def initialize
      SECTIONS.each { |name, klass| instance_variable_set(:"@#{name}", klass.new(self)) }
      @enabled = true
      @log_level = :info
      @auto_enable_stream_usage = true
      @cache_rollups = false
      @instrumented_integrations = Set.new
      self.openai_compatible_providers = OPENAI_COMPATIBLE_PROVIDERS
      @finalized = false
    end

    def openai_compatible_providers=(providers)
      ensure_mutable!
      @openai_compatible_providers = normalize_openai_compatible_providers(providers)
    end

    def instrument(*names)
      ensure_mutable!
      names = names.flatten
      names = Integrations.names if names == [:all]
      @instrumented_integrations.merge(names)
    end

    def instrumented?(name)
      @instrumented_integrations.include?(name)
    end

    SCALAR_ATTRIBUTES.each do |name|
      define_method(:"#{name}=") do |value|
        ensure_mutable!
        instance_variable_set(:"@#{name}", value)
      end
    end

    DEPRECATED_ATTRIBUTES.each do |old_name, (section, new_name)|
      define_method(old_name) do
        LlmCostTracker.deprecator.warn("config.#{old_name} is deprecated; use config.#{section}.#{new_name}")
        public_send(section).public_send(new_name)
      end

      define_method(:"#{old_name}=") do |value|
        LlmCostTracker.deprecator.warn("config.#{old_name}= is deprecated; use config.#{section}.#{new_name}=")
        public_send(section).public_send(:"#{new_name}=", value)
      end
    end

    DEPRECATED_WRITERS.each do |old_name, (section, new_name)|
      define_method(:"#{old_name}=") do |value|
        LlmCostTracker.deprecator.warn("config.#{old_name}= is deprecated; use config.#{section}.#{new_name}=")
        public_send(section).public_send(:"#{new_name}=", value)
      end
    end

    def log_level
      LlmCostTracker.deprecator.warn(LOG_LEVEL_DEPRECATION)
      @log_level
    end

    def log_level=(value)
      ensure_mutable!
      LlmCostTracker.deprecator.warn(LOG_LEVEL_DEPRECATION)
      @log_level = value
    end

    def finalize!
      SECTIONS.each_key { |name| public_send(name).finalize! }
      @instrumented_integrations = deep_freeze(@instrumented_integrations || Set.new)
      @openai_compatible_providers = deep_freeze(
        normalize_openai_compatible_providers(@openai_compatible_providers)
      )
      @finalized = true
    end

    def finalized?
      @finalized
    end

    private

    def normalize_openai_compatible_providers(providers)
      (providers || {}).each_with_object({}) do |(host, provider), normalized|
        normalized[host.to_s.downcase] = provider.to_s
      end
    end
  end
end
