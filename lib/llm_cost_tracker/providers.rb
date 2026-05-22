# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Anthropic
      autoload :Parser,               "llm_cost_tracker/providers/anthropic/parser"
      autoload :ReconciliationSource, "llm_cost_tracker/providers/anthropic/reconciliation_source"
      autoload :TierClassification,   "llm_cost_tracker/providers/anthropic/tier_classification"
      autoload :UsageExtractor,       "llm_cost_tracker/providers/anthropic/usage_extractor"
    end

    module Azure
      autoload :Hosts,  "llm_cost_tracker/providers/azure/hosts"
      autoload :Parser, "llm_cost_tracker/providers/azure/parser"
    end

    module Gemini
      autoload :ModelFamilies, "llm_cost_tracker/providers/gemini/model_families"
      autoload :Parser,        "llm_cost_tracker/providers/gemini/parser"
    end

    module Openai
      autoload :Hosts,                "llm_cost_tracker/providers/openai/hosts"
      autoload :ModelFamilies,        "llm_cost_tracker/providers/openai/model_families"
      autoload :Parser,               "llm_cost_tracker/providers/openai/parser"
      autoload :ReconciliationSource, "llm_cost_tracker/providers/openai/reconciliation_source"
      autoload :ServiceCharges,       "llm_cost_tracker/providers/openai/service_charges"
      autoload :UsageExtractor,       "llm_cost_tracker/providers/openai/usage_extractor"
      autoload :UsageParser,          "llm_cost_tracker/providers/openai/usage_parser"
    end

    module OpenaiCompatible
      autoload :Parser, "llm_cost_tracker/providers/openai_compatible/parser"
    end
  end
end
