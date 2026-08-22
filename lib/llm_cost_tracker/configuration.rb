# frozen_string_literal: true

require_relative "errors"
require_relative "deprecator"
require_relative "pricing/registry"
require_relative "tags/key"
require_relative "configuration/budgets"
require_relative "configuration/capture"
require_relative "configuration/ingestion"
require_relative "configuration/pricing"
require_relative "configuration/tags"

module LlmCostTracker
  class Configuration
    include Mutability

    SECTIONS = {
      budgets: Budgets, capture: Capture, ingestion: Ingestion, pricing: Pricing, tags: Tags
    }.freeze

    SCALAR_ATTRIBUTES = %i[enabled cache_period_totals].freeze

    DEPRECATED_OPTIONS = {
      monthly_budget: { to: %i[budgets monthly] },
      daily_budget: { to: %i[budgets daily] },
      per_call_budget: { to: %i[budgets per_call] },
      budget_exceeded_behavior: { to: %i[budgets exceeded_behavior] },
      on_budget_exceeded: { to: %i[budgets on_exceeded] },
      default_tags: { to: %i[tags default] },
      max_tag_count: { to: %i[tags max_count] },
      max_tag_value_bytesize: { to: %i[tags max_value_bytesize] },
      redacted_tag_keys: { to: %i[tags redacted_keys] },
      report_tag_breakdowns: { to: %i[tags report_breakdown_keys] },
      prices_file: { to: %i[pricing file] },
      pricing_overrides: { to: %i[pricing overrides] },
      unknown_pricing_behavior: { to: %i[pricing unknown_model_behavior] },
      ingestion_pool_size: { to: %i[ingestion pool_size] },
      auto_enable_stream_usage: { to: %i[capture request_stream_usage] },
      openai_compatible_providers: { to: %i[capture openai_compatible_providers] },
      cache_rollups: { to: %i[cache_period_totals] },
      ingestion: { to: %i[ingestion mode], writer_only: true },
      log_level: { to: nil, note: "LlmCostTracker logs through Rails.logger, which owns the level" }
    }.freeze

    attr_reader(*SCALAR_ATTRIBUTES, *SECTIONS.keys, :instrumented_integrations)

    def initialize
      SECTIONS.each { |name, klass| instance_variable_set(:"@#{name}", klass.new(self)) }
      @enabled = true
      @log_level = :info
      @cache_period_totals = false
      @instrumented_integrations = Set.new
      @finalized = false
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

    DEPRECATED_OPTIONS.each do |old_name, spec|
      path = spec[:to]
      replacement = path ? "config.#{path.join('.')}" : nil

      define_method(:"#{old_name}=") do |value|
        LlmCostTracker.deprecator.warn(deprecation_message(old_name, replacement, spec[:note], writer: true))
        next instance_variable_set(:"@#{old_name}", value) unless path

        ensure_mutable! if path.size == 1
        target = path[0..-2].inject(self) { |object, step| object.public_send(step) }
        target.public_send(:"#{path.last}=", value)
      end

      next if spec[:writer_only]

      define_method(old_name) do
        LlmCostTracker.deprecator.warn(deprecation_message(old_name, replacement, spec[:note], writer: false))
        next instance_variable_get(:"@#{old_name}") unless path

        path.inject(self) { |object, step| object.public_send(step) }
      end
    end

    def finalize!
      SECTIONS.each_key { |name| public_send(name).finalize! }
      @instrumented_integrations = deep_freeze(@instrumented_integrations || Set.new)
      @finalized = true
    end

    def finalized?
      @finalized
    end

    private

    def deprecation_message(old_name, replacement, note, writer:)
      suffix = writer ? "=" : ""
      name = "config.#{old_name}#{suffix}"
      return "#{name} is deprecated; use #{replacement}#{suffix}" if replacement

      "#{name} is deprecated and has no effect; #{note}"
    end
  end
end
