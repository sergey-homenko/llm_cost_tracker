# frozen_string_literal: true

require "spec_helper"

RSpec.describe "gem package files" do
  let(:gemspec) { Gem::Specification.load(File.expand_path("../../llm_cost_tracker.gemspec", __dir__)) }

  it "excludes repository documentation" do
    expect(gemspec.files.grep(%r{\Adocs/})).to be_empty
  end

  it "keeps runtime files and top-level documentation" do
    expect(gemspec.files).to include("lib/llm_cost_tracker.rb", "README.md", "CHANGELOG.md")
  end
end
