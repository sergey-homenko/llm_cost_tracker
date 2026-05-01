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
end
