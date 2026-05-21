# frozen_string_literal: true

require_relative "lib/llm_cost_tracker/version"

Gem::Specification.new do |spec|
  spec.name          = "llm_cost_tracker"
  spec.version       = LlmCostTracker::VERSION
  spec.authors       = ["Sergii Khomenko"]
  spec.email         = ["sergey@mm.st"]

  spec.summary       = "LLM API cost tracking for Rails applications"
  spec.description   = "Logs every call your Rails app makes to OpenAI, Anthropic, Gemini, RubyLLM, " \
                       "or an OpenAI-compatible API: tokens, cost, latency, tags. Calls go straight " \
                       "to the provider — no proxy. Includes price sync, budget guardrails, and a " \
                       "mountable dashboard."
  spec.homepage      = "https://github.com/sergey-homenko/llm_cost_tracker"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = "#{spec.homepage}#readme"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?("bin/", "test/", "spec/", "scripts/", "docs/", ".git", ".github",
                      "gemfiles/", ".rubocop", "Gemfile") ||
        f == "codecov.yml"
    end
  end

  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.1", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.1", "< 9.0"
  spec.add_dependency "csv", "~> 3.0"
  spec.add_dependency "faraday", ">= 2.0", "< 3.0"
  spec.add_dependency "railties", ">= 7.1", "< 9.0"

  spec.add_development_dependency "anthropic", "~> 1.42"
  spec.add_development_dependency "nokogiri", "~> 1.16"
  spec.add_development_dependency "openai", "~> 0.63"
  spec.add_development_dependency "pg", "~> 1.6"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "rubocop", "~> 1.0"
  spec.add_development_dependency "ruby_llm", "~> 1.15"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "simplecov-lcov", "~> 0.8"
  spec.add_development_dependency "webmock", "~> 3.0"
end
