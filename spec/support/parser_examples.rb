# frozen_string_literal: true

RSpec.shared_examples "a parser with common usage failure handling" do |url:, request_body:,
                                                                        response_body:, missing_usage_body:|
  it "returns nil for non-200 responses" do
    result = parser.parse(url, request_body, 429, response_body)

    expect(result).to be_nil
  end

  it "returns nil when usage is missing" do
    result = parser.parse(url, request_body, 200, missing_usage_body)

    expect(result).to be_nil
  end
end
