# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Parsers::Base do
  describe "#parse" do
    it "requires concrete parsers to implement response parsing" do
      expect { described_class.new.parse }.to raise_error(NotImplementedError)
    end
  end

  describe "#parse_stream" do
    it "defaults missing stream context to no capture" do
      expect(described_class.new.parse_stream).to be_nil
    end
  end

  describe "#auto_enable_stream_usage?" do
    it "returns false by default so middleware does not modify provider request bodies" do
      expect(described_class.new.auto_enable_stream_usage?("https://api.anthropic.com/v1/messages")).to be false
    end
  end
end
