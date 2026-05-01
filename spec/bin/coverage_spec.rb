# frozen_string_literal: true

require "tempfile"

load File.expand_path("../../bin/coverage", __dir__)

RSpec.describe LcovReport do
  def build_report(body)
    Tempfile.create("lcov") do |file|
      file.write(body)
      file.flush
      described_class.new(file.path)
    end
  end

  it "treats partially covered branch lines as uncovered" do
    report = build_report(<<~LCOV)
      SF:#{Dir.pwd}/lib/example.rb
      DA:10,1
      DA:11,1
      DA:12,0
      BRDA:11,0,0,1
      BRDA:11,0,1,-
      end_of_record
    LCOV

    expect(report).to be_covered("lib/example.rb", 10)
    expect(report).not_to be_covered("lib/example.rb", 11)
    expect(report).not_to be_covered("lib/example.rb", 12)
    expect(report.covered_lines).to eq(1)
    expect(report.total_lines).to eq(3)
  end

  it "treats fully covered branch lines as covered" do
    report = build_report(<<~LCOV)
      SF:#{Dir.pwd}/lib/example.rb
      DA:20,1
      BRDA:20,0,0,1
      BRDA:20,0,1,2
      end_of_record
    LCOV

    expect(report).to be_covered("lib/example.rb", 20)
    expect(report.covered_lines).to eq(1)
    expect(report.total_lines).to eq(1)
  end
end

RSpec.describe Git do
  describe ".coverage_base" do
    it "uses the current commit parent when it exists" do
      allow(described_class).to receive(:capture)
        .with("rev-parse", "--verify", "HEAD^", allow_failure: true)
        .and_return("abc123\n")

      expect(described_class.coverage_base).to eq("abc123")
    end

    it "falls back to HEAD when the current commit has no parent" do
      allow(described_class).to receive(:capture)
        .with("rev-parse", "--verify", "HEAD^", allow_failure: true)
        .and_return("")

      expect(described_class.coverage_base).to eq("HEAD")
    end
  end
end
