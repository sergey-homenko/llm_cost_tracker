# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Redaction do
  let(:gemini_key) { "AIzaSy#{'A1b2C3d4' * 4}x" }

  it "scrubs credential params, URL user info, authorization headers and provider keys" do
    {
      "POST https://g.example/v1beta/models/m:streamGenerateContent?alt=sse&key=#{gemini_key}" =>
        "POST https://g.example/v1beta/models/m:streamGenerateContent?alt=sse&key=[REDACTED]",
      "https://r.openai.azure.com/x?api-version=1&api-key=abc123&sig=Zm9v%2Bbar&se=2026" =>
        "https://r.openai.azure.com/x?api-version=1&api-key=[REDACTED]&sig=[REDACTED]&se=2026",
      "https://user:pa55word@proxy.internal/v1" => "https://[REDACTED]@proxy.internal/v1",
      "Authorization: Basic dXNlcjpwYXNzd29yZA==" => "Authorization: [REDACTED]",
      %({"Authorization"=>"Bearer abc123", "api-key" => "0123456789abcdef"}) =>
        %({"Authorization"=>"[REDACTED]", "api-key" => "[REDACTED]"}),
      "key #{gemini_key} rejected" => "key [REDACTED] rejected",
      "used sk-ant-#{'a' * 30}." => "used [REDACTED]."
    }.each { |input, output| expect(described_class.text(input)).to eq(output) }
  end

  it "leaves diagnostic text alone" do
    [
      "Access denied for user 'lct'@'10.0.0.5' (using password: YES)",
      "Faraday::ConnectionFailed: Failed to open TCP connection to api.openai.com:443 (Connection refused)",
      "https://app.example.com/search?q=shoes&page=2",
      "error_code=429 monkey=1 task-abcdefghijklmnopqrstuvwxyz"
    ].each { |text| expect(described_class.text(text)).to eq(text) }
  end
end
