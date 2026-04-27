# frozen_string_literal: true

require_relative "lib/llm_cost_tracker/version"

Gem::Specification.new do |spec|
  spec.name          = "llm_cost_tracker"
  spec.version       = LlmCostTracker::VERSION
  spec.authors       = ["Sergii Khomenko"]
  spec.email         = ["sergey@mm.st"]

  spec.summary       = "Self-hosted LLM usage and cost tracking for Ruby and Rails"
  spec.description   = "Tracks token usage, latency, and estimated costs for RubyLLM, OpenAI, Anthropic, " \
                       "Google Gemini, OpenRouter, DeepSeek, and OpenAI-compatible APIs. " \
                       "Works through Faraday middleware or explicit track/track_stream helpers, " \
                       "with ActiveRecord storage, tag-based attribution, price sync tasks, " \
                       "and budget guardrails."
  spec.homepage      = "https://github.com/sergey-homenko/llm_cost_tracker"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = "#{spec.homepage}#readme"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?("bin/", "docs/", "test/", "spec/", "scripts/", ".git", ".github",
                      "gemfiles/", ".rubocop", "Gemfile")
    end
  end

  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", ">= 7.1", "< 9.0"
  spec.add_dependency "csv", "~> 3.0"
  spec.add_dependency "faraday", ">= 2.0", "< 3.0"

  spec.add_development_dependency "activerecord", ">= 7.1", "< 9.0"
  spec.add_development_dependency "nokogiri", "~> 1.16"
  spec.add_development_dependency "railties", ">= 7.1", "< 9.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "rubocop", "~> 1.0"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "simplecov-lcov", "~> 0.8"
  spec.add_development_dependency "sqlite3", ">= 1.4", "< 3.0"
  spec.add_development_dependency "webmock", "~> 3.0"
end
