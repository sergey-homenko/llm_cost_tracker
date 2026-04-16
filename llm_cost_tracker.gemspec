# frozen_string_literal: true

require_relative "lib/llm_cost_tracker/version"

Gem::Specification.new do |spec|
  spec.name          = "llm_cost_tracker"
  spec.version       = LlmCostTracker::VERSION
  spec.authors       = ["Sergii Khomenko"]
  spec.email         = ["sergey@mm.st"]

  spec.summary       = "Provider-agnostic LLM API cost tracking for Ruby"
  spec.description   = "Automatically tracks token usage and costs for LLM API calls (OpenAI, Anthropic, Google Gemini, and more). " \
                        "Works as Faraday middleware — plugs into any Ruby HTTP client. " \
                        "Provides ActiveRecord storage, per-user/per-feature attribution, and budget alerts."
  spec.homepage      = "https://github.com/sergey-homenko/llm_cost_tracker"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?("bin/", "test/", "spec/", ".git", ".github", "Gemfile")
    end
  end

  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", ">= 1.0", "< 3.0"
  spec.add_dependency "activesupport", ">= 7.0"

  spec.add_development_dependency "activerecord", ">= 7.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "webmock", "~> 3.0"
  spec.add_development_dependency "sqlite3"
  spec.add_development_dependency "rubocop", "~> 1.0"
end
