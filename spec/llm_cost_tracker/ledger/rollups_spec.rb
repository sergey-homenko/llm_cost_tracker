# frozen_string_literal: true

require "spec_helper"

require_relative "../../dummy/config/environment"

RSpec.describe LlmCostTracker::Ledger::Rollups do
  describe ".currency_for (private)" do
    it "reads currency from pricing_snapshot when present" do
      event = double(pricing_snapshot: { "currency" => "EUR" })

      expect(described_class.send(:currency_for, event)).to eq("EUR")
    end

    it "supports symbol keys on pricing_snapshot" do
      event = double(pricing_snapshot: { currency: "GBP" })

      expect(described_class.send(:currency_for, event)).to eq("GBP")
    end

    it "falls back to USD when pricing_snapshot is nil" do
      event = double(pricing_snapshot: nil)

      expect(described_class.send(:currency_for, event)).to eq("USD")
    end

    it "falls back to USD when pricing_snapshot is not a hash" do
      event = double(pricing_snapshot: "weird")

      expect(described_class.send(:currency_for, event)).to eq("USD")
    end

    it "falls back to USD when the event does not respond to pricing_snapshot" do
      event = Object.new

      expect(described_class.send(:currency_for, event)).to eq("USD")
    end
  end
end
