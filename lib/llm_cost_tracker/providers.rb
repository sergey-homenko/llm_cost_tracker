# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Anthropic
      autoload :Parser,               "llm_cost_tracker/providers/anthropic/parser"
      autoload :UsageExtractor,       "llm_cost_tracker/providers/anthropic/usage_extractor"
      autoload :ResponseParser, "llm_cost_tracker/providers/anthropic/response_parser"
    end

    module Azure
      autoload :Hosts,  "llm_cost_tracker/providers/azure/hosts"
      autoload :Parser, "llm_cost_tracker/providers/azure/parser"
    end

    module Gemini
      autoload :ModelFamilies,  "llm_cost_tracker/providers/gemini/model_families"
      autoload :Parser,         "llm_cost_tracker/providers/gemini/parser"
      autoload :UsageExtractor, "llm_cost_tracker/providers/gemini/usage_extractor"
    end

    module Openai
      autoload :Hosts,                "llm_cost_tracker/providers/openai/hosts"
      autoload :ModelFamilies,        "llm_cost_tracker/providers/openai/model_families"
      autoload :Parser,               "llm_cost_tracker/providers/openai/parser"
      autoload :ServiceCharges,       "llm_cost_tracker/providers/openai/service_charges"
      autoload :UsageExtractor,       "llm_cost_tracker/providers/openai/usage_extractor"
      autoload :ResponseParser, "llm_cost_tracker/providers/openai/response_parser"
    end

    module OpenaiCompatible
      autoload :Parser, "llm_cost_tracker/providers/openai_compatible/parser"
    end
  end
end
