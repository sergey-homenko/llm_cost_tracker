# frozen_string_literal: true

require "spec_helper"
require "price_scrape/fetcher"

RSpec.describe LlmCostTracker::PriceScrape::Fetcher do
  let(:url) { "https://example.com/page" }
  let(:fetcher) { described_class.new(sleep: ->(_seconds) {}) }

  it "returns a Response with UTF-8 body on 200 OK" do
    stub_request(:get, url).to_return(status: 200, body: "Привет")

    response = fetcher.get(url)

    expect(response.url).to eq(url)
    expect(response.body).to eq("Привет")
    expect(response.body.encoding).to eq(Encoding::UTF_8)
    expect(response.status).to eq(200)
    expect(response.elapsed_ms).to be >= 0
  end

  it "sets the configured User-Agent header" do
    stub = stub_request(:get, url)
           .with(headers: { "User-Agent" => described_class::DEFAULT_USER_AGENT })
           .to_return(status: 200, body: "ok")

    fetcher.get(url)

    expect(stub).to have_been_requested
  end

  it "follows redirects up to the limit" do
    stub_request(:get, url).to_return(status: 302, headers: { "Location" => "https://example.com/next" })
    stub_request(:get, "https://example.com/next").to_return(status: 200, body: "ok")

    expect(fetcher.get(url).body).to eq("ok")
  end

  it "raises after too many redirects" do
    stub_request(:get, url).to_return(status: 302, headers: { "Location" => url })

    expect { fetcher.get(url) }.to raise_error(described_class::Error, /too many redirects/)
  end

  it "retries on transient server errors and succeeds on a later attempt" do
    stub_request(:get, url)
      .to_return(status: 503).then
      .to_return(status: 200, body: "ok")

    expect(fetcher.get(url).body).to eq("ok")
  end

  it "raises ServerError after exhausting attempts" do
    stub_request(:get, url).to_return(status: 503)

    expect { fetcher.get(url) }.to raise_error(described_class::ServerError, /server error 503/)
  end

  it "retries on network errors and surfaces NetworkError after exhausting attempts" do
    stub_request(:get, url).to_raise(Errno::ECONNRESET.new("connection reset"))

    expect { fetcher.get(url) }.to raise_error(described_class::NetworkError, /Errno::ECONNRESET/)
  end

  it "raises immediately on 4xx without retries" do
    stub_request(:get, url).to_return(status: 404)

    expect { fetcher.get(url) }.to raise_error(described_class::Error, /client error 404/)
    expect(WebMock).to have_requested(:get, url).once
  end

  it "rejects non-https URLs" do
    expect { fetcher.get("http://example.com") }.to raise_error(described_class::Error, /non-https URL/)
  end

  it "rejects an empty response body" do
    stub_request(:get, url).to_return(status: 200, body: "")

    expect { fetcher.get(url) }.to raise_error(described_class::Error, /empty response body/)
  end

  it "rejects oversized response bodies" do
    stub_request(:get, url).to_return(status: 200, body: "x" * (described_class::MAX_BODY_BYTES + 1))

    expect { fetcher.get(url) }.to raise_error(described_class::Error, /response body exceeds/)
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

    expect { fetcher.get(url) }.to raise_error(described_class::Error, /response body exceeds/)
    expect(chunks).to eq(1)
  end

  it "rejects a redirect without a Location header" do
    stub_request(:get, url).to_return(status: 302)

    expect { fetcher.get(url) }.to raise_error(described_class::Error, /redirect without location/)
  end

  it "sleeps with exponential backoff between retry attempts" do
    delays = []
    fetcher = described_class.new(sleep: ->(seconds) { delays << seconds })
    stub_request(:get, url).to_return(status: 503)

    expect { fetcher.get(url) }.to raise_error(described_class::ServerError)
    expect(delays).to eq([1.0, 2.0])
  end
end
