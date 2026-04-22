# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::PriceSync::Fetcher do
  describe "#get" do
    it "configures explicit network timeouts" do
      response = Net::HTTPOK.new("1.1", "200", "OK")
      allow(response).to receive(:body).and_return("{}")
      allow(response).to receive(:[]).with("etag").and_return(nil)
      allow(response).to receive(:[]).with("last-modified").and_return(nil)

      expect(Net::HTTP).to receive(:start).with(
        "example.com",
        443,
        use_ssl: true,
        open_timeout: 5,
        read_timeout: 10,
        write_timeout: 10
      ).and_yield(instance_double(Net::HTTP, request: response))

      described_class.new.get("https://example.com/prices.json")
    end
  end
end
