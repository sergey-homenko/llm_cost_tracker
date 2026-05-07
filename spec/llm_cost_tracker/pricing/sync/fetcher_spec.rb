# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Pricing::Sync::Fetcher do
  describe "#get" do
    it "configures explicit network timeouts" do
      response = Net::HTTPOK.new("1.1", "200", "OK")
      allow(response).to receive(:read_body).and_yield("{}")
      allow(response).to receive(:[]).with("etag").and_return(nil)
      allow(response).to receive(:[]).with("last-modified").and_return(nil)
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request).and_yield(response).and_return(response)

      expect(Net::HTTP).to receive(:start).with(
        "example.com",
        443,
        use_ssl: true,
        open_timeout: 5,
        read_timeout: 10,
        write_timeout: 10
      ).and_yield(http)

      described_class.new.get("https://example.com/prices.json")
    end

    it "sends a versioned user agent" do
      response = Net::HTTPOK.new("1.1", "200", "OK")
      allow(response).to receive(:read_body).and_yield("{}")
      allow(response).to receive(:[]).with("etag").and_return(nil)
      allow(response).to receive(:[]).with("last-modified").and_return(nil)
      http = instance_double(Net::HTTP)
      request = nil
      allow(http).to receive(:request) do |incoming_request, &block|
        request = incoming_request
        block.call(response)
        response
      end
      allow(Net::HTTP).to receive(:start).and_yield(http)

      described_class.new.get("https://example.com/prices.json")

      expect(request["User-Agent"]).to eq("llm_cost_tracker/#{LlmCostTracker::VERSION} price refresh")
    end

    it "wraps SSL failures as price refresh errors" do
      allow(Net::HTTP).to receive(:start).and_raise(OpenSSL::SSL::SSLError, "certificate verify failed")

      expect do
        described_class.new.get("https://example.com/prices.json")
      end.to raise_error(LlmCostTracker::Error, /Unable to fetch .*OpenSSL::SSL::SSLError/)
    end

    it "rejects unsupported URL schemes before opening a connection" do
      expect(Net::HTTP).not_to receive(:start)

      expect do
        described_class.new.get("file:///tmp/prices.json")
      end.to raise_error(LlmCostTracker::Error, /must use https/)
    end

    it "rejects http URLs before opening a connection" do
      expect(Net::HTTP).not_to receive(:start)

      expect do
        described_class.new.get("http://example.com/prices.json")
      end.to raise_error(LlmCostTracker::Error, /must use https/)
    end

    it "rejects oversized response bodies" do
      response = Net::HTTPOK.new("1.1", "200", "OK")
      allow(response).to receive(:read_body).and_yield("x" * (described_class::MAX_BODY_BYTES + 1))
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request).and_yield(response).and_return(response)

      allow(Net::HTTP).to receive(:start).and_yield(http)

      expect do
        described_class.new.get("https://example.com/prices.json")
      end.to raise_error(LlmCostTracker::Error, /exceeds/)
    end

    it "stops reading successful bodies after the configured byte cap" do
      response = Net::HTTPOK.new("1.1", "200", "OK")
      chunks = 0
      allow(response).to receive(:read_body) do |&block|
        block.call("x" * described_class::MAX_BODY_BYTES)
        chunks += 1
        block.call("x")
        chunks += 1
      end
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request).and_yield(response).and_return(response)
      allow(Net::HTTP).to receive(:start).and_yield(http)

      expect do
        described_class.new.get("https://example.com/prices.json")
      end.to raise_error(LlmCostTracker::Error, /exceeds/)
      expect(chunks).to eq(1)
    end

    it "scrubs credentials and query strings from error messages" do
      allow(Net::HTTP).to receive(:start).and_raise(SocketError, "DNS lookup failed")

      expect do
        described_class.new.get("https://user:secret@example.com/prices.json?token=abc#section")
      end.to raise_error(LlmCostTracker::Error) { |error|
        expect(error.message).to include("https://example.com/prices.json")
        expect(error.message).not_to include("secret")
        expect(error.message).not_to include("token=abc")
        expect(error.message).not_to include("section")
      }
    end

    it "returns an invalid url placeholder when scrubbing an unparsable url" do
      expect(described_class.new.send(:scrub_url, "https://[bad]")).to eq("[invalid url]")
    end

    it "scrubs the url when raising too-many-redirects" do
      expect do
        described_class.new.get(
          "https://user:secret@example.com/prices.json?token=abc",
          redirects: described_class::MAX_REDIRECTS + 1
        )
      end.to raise_error(LlmCostTracker::Error) { |error|
        expect(error.message).to include("Too many redirects")
        expect(error.message).to include("https://example.com/prices.json")
        expect(error.message).not_to include("secret")
        expect(error.message).not_to include("token=abc")
      }
    end

    it "raises with a scrubbed url when a redirect is missing its location header" do
      response = Net::HTTPMovedPermanently.new("1.1", "301", "Moved Permanently")
      allow(response).to receive(:[]).with("location").and_return(nil)
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request).and_yield(response).and_return(response)
      allow(Net::HTTP).to receive(:start).and_yield(http)

      expect do
        described_class.new.get("https://user:secret@example.com/prices.json")
      end.to raise_error(LlmCostTracker::Error) { |error|
        expect(error.message).to include("Redirect without location")
        expect(error.message).not_to include("secret")
      }
    end

    it "raises with a scrubbed url and HTTP code on unhandled response statuses" do
      response = Net::HTTPInternalServerError.new("1.1", "500", "Internal Server Error")
      allow(response).to receive(:read_body)
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request).and_yield(response).and_return(response)
      allow(Net::HTTP).to receive(:start).and_yield(http)

      expect do
        described_class.new.get("https://user:secret@example.com/prices.json")
      end.to raise_error(LlmCostTracker::Error) { |error|
        expect(error.message).to include("HTTP 500")
        expect(error.message).not_to include("secret")
      }
    end
  end
end
