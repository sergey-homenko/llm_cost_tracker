# frozen_string_literal: true

require_relative "lib/llm_cost_tracker/version"

Gem::Specification.new do |spec|
  spec.name          = "llm_cost_tracker"
  spec.version       = LlmCostTracker::VERSION
  spec.authors       = ["Sergii Khomenko"]
  spec.email         = ["sergey@mm.st"]

  spec.summary       = "Self-hosted LLM API cost tracking for Ruby and Rails"
  spec.description   = "Tracks token usage and estimated costs for OpenAI, Anthropic, and Google Gemini calls. " \
                       "Works as Faraday middleware for Ruby clients, with ActiveRecord storage, " \
                       "per-user/per-feature attribution, and budget alerts."
  spec.homepage      = "https://github.com/sergey-homenko/llm_cost_tracker"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"]  = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?("bin/", "test/", "spec/", ".git", ".github", "Gemfile")
    end
  end

  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", ">= 7.0", "< 9.0"
  spec.add_dependency "faraday", ">= 1.0", "< 3.0"

  spec.add_development_dependency "activerecord", ">= 7.0", "< 9.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "rubocop", "~> 1.0"
  spec.add_development_dependency "sqlite3", "~> 2.0"
  spec.add_development_dependency "webmock", "~> 3.0"
end
