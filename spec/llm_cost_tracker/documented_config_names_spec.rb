# frozen_string_literal: true

require "spec_helper"

RSpec.describe "documented configuration names" do
  ROOT = Pathname.new(File.expand_path("../..", __dir__))
  HISTORICAL = ["docs/upgrading.md", "CHANGELOG.md"].freeze

  def scanned_files
    patterns = ["docs/**/*.md", "README.md", "scripts/**/*.rb",
                "lib/llm_cost_tracker/generators/**/*.erb", "lib/llm_cost_tracker/generators/**/*.rb"]
    patterns.flat_map { |pattern| Dir.glob(ROOT.join(pattern)) }
            .map { |path| Pathname.new(path).relative_path_from(ROOT).to_s }
            .reject { |path| HISTORICAL.include?(path) }
  end

  def offences_for(pattern)
    scanned_files.flat_map do |path|
      ROOT.join(path).read.each_line.with_index(1).filter_map do |line, number|
        "#{path}:#{number} #{line.strip}" if line.match?(pattern)
      end
    end
  end

  it "teaches no deprecated option name outside the historical documents" do
    names = LlmCostTracker::Configuration::DEPRECATED_OPTIONS.keys.map { |name| Regexp.escape(name.to_s) }
    offences = offences_for(/\bconfig\.(#{names.join("|")})\b(?!\.)/)

    expect(offences).to be_empty, "deprecated config names still documented:\n  #{offences.join("\n  ")}"
  end

  it "contains no doubled config receiver left behind by a bulk rename" do
    offences = offences_for(/config\.\W*config\./)

    expect(offences).to be_empty, "corrupted config references:\n  #{offences.join("\n  ")}"
  end
end
