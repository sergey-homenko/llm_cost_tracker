# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Logging do
  around do |example|
    previous = Rails.logger
    example.run
  ensure
    Rails.logger = previous
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
