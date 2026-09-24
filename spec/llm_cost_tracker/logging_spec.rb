# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Logging do
  around do |example|
    previous = Rails.logger
    example.run
  ensure
    Rails.logger = previous
  end

  it "scrubs credentials out of warning text" do
    buffer = StringIO.new
    Rails.logger = Logger.new(buffer)
    key = "AIzaSy#{'A1b2C3d4' * 4}x"

    described_class.warn("Error processing response: Faraday::ServerError: the server responded with status 503 " \
                         "for POST https://generativelanguage.googleapis.com/v1beta/models/m:generateContent?key=#{key}")

    expect(buffer.string).to include("generativelanguage.googleapis.com/v1beta/models/m:generateContent")
    expect(buffer.string).not_to include(key)
  end

  it "writes a warning whose text is not valid UTF-8 instead of raising" do
    buffer = StringIO.new
    Rails.logger = Logger.new(buffer)

    expect { described_class.warn("broken \xFF bytes".dup.force_encoding(Encoding::UTF_8)) }.not_to raise_error
    expect(buffer.string).to include("broken")
  end

  it "writes through a host logger that does not support tagging" do
    buffer = StringIO.new
    Rails.logger = Logger.new(buffer)

    expect { described_class.warn("plain logger") }.not_to raise_error
    expect(buffer.string).to include("[LlmCostTracker] plain logger")
  end

  it "writes through a tagged host logger" do
    buffer = StringIO.new
    Rails.logger = ActiveSupport::TaggedLogging.new(Logger.new(buffer))

    described_class.warn("tagged logger")

    expect(buffer.string).to include("[LlmCostTracker] tagged logger")
  end
end
