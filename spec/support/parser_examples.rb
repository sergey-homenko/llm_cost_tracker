# frozen_string_literal: true

RSpec.shared_examples "a parser with common usage failure handling" do |url:, request_body:,
                                                                        response_body:, missing_usage_body:|
  it "returns nil for non-200 responses" do
    result = parser.parse(
      request_url: url,
      request_body: request_body,
      response_status: 429,
      response_body: response_body
    )

    expect(result).to be_nil
  end

  it "returns nil when usage is missing" do
    result = parser.parse(
      request_url: url,
      request_body: request_body,
      response_status: 200,
      response_body: missing_usage_body
    )

    expect(result).to be_nil
  end
end

RSpec.shared_examples "a parser with invalid URL handling" do
  it "returns false for invalid URLs" do
    expect(parser.match?("https://%zz")).to be false
  end
end
