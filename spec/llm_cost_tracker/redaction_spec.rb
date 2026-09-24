# frozen_string_literal: true

require "spec_helper"
require "cgi"

RSpec.describe LlmCostTracker::Redaction do
  subject(:redaction) { described_class }

  let(:gemini_key) { "AIzaSy#{'A1b2C3d4' * 4}x" }

  it "scrubs sensitive query params but keeps the rest of the URL" do
    text = "for POST https://generativelanguage.googleapis.com/v1beta/models/m:streamGenerateContent?alt=sse&key=#{gemini_key}"
    expect(redaction.text(text))
      .to eq("for POST https://generativelanguage.googleapis.com/v1beta/models/m:streamGenerateContent?alt=sse&key=[REDACTED]")
  end

  it "scrubs Azure api-key and SAS sig params" do
    expect(redaction.text("https://r.openai.azure.com/x?api-version=1&api-key=abc123&sig=Zm9v%2Bbar&se=2026"))
      .to eq("https://r.openai.azure.com/x?api-version=1&api-key=[REDACTED]&sig=[REDACTED]&se=2026")
  end

  it "scrubs userinfo, bearer tokens, authorization headers and embedded provider keys" do
    expect(redaction.text("https://user:pa55word@proxy.internal/v1")).to eq("https://[REDACTED]@proxy.internal/v1")
    expect(redaction.text("Authorization: Bearer abcdefghijklmnopqrstuvwxyz")).not_to include("abcdefghij")
    expect(redaction.text(%({"x-goog-api-key"=>"#{gemini_key}"}))).not_to include(gemini_key)
    expect(redaction.text("key #{gemini_key} rejected")).to eq("key [REDACTED] rejected")
    expect(redaction.text("used sk-ant-#{'a' * 30}.")).to eq("used [REDACTED].")
  end

  it "scrubs credentials in header, hash and JSON forms whatever the auth scheme" do
    hex = "0123456789abcdef0123456789abcdef"

    {
      "api-key: #{hex}" => "api-key: [REDACTED]",
      "X_API_KEY: #{hex}" => "X_API_KEY: [REDACTED]",
      "Authorization: Basic dXNlcjpwYXNzd29yZA==" => "Authorization: [REDACTED]",
      "Authorization: Bearer abc123" => "Authorization: [REDACTED]",
      "Authorization: Key #{hex}" => "Authorization: [REDACTED]",
      %("HTTP_AUTHORIZATION"=>"Basic dXNlcjpodW50ZXIy") => %("HTTP_AUTHORIZATION"=>"[REDACTED]"),
      %({"password":"hunter2"}) => %({"password":"[REDACTED]"}),
      %({\"api_key\":\"#{hex}\"}) => %({\"api_key\":\"[REDACTED]\"}),
      %({api_key: "#{hex}"}) => %({api_key: "[REDACTED]"})
    }.each { |input, output| expect(redaction.text(input)).to eq(output) }
  end

  it "scrubs percent-encoded and JSON-escaped parameters and keys" do
    nested = "https://proxy.example/fetch?target=#{CGI.escape("https://g.example/v1/m:gen?key=#{gemini_key}")}"

    expect(redaction.text(nested)).not_to include(gemini_key)
    expect(redaction.text("a=1%26api-key%3D#{'f' * 32}")).not_to include("f" * 32)
    expect(redaction.text(%({"url":"https://r/x?v=1\\u0026api-key=#{'f' * 32}"}))).not_to include("f" * 32)
  end

  it "keeps short values and prose that only mention a credential name" do
    [
      "Access denied for user 'lct'@'10.0.0.5' (using password: YES)",
      "password: set",
      "user_password: set",
      "Authorization: none"
    ].each { |text| expect(redaction.text(text)).to eq(text) }
  end

  it "leaves diagnostic text alone" do
    [
      "Faraday::ConnectionFailed: Failed to open TCP connection to api.openai.com:443 (Connection refused)",
      "Net::ReadTimeout with #<TCPSocket:(closed)>",
      "https://app.example.com/search?q=shoes&page=2",
      "error_code=429 monkey=1 task-abcdefghijklmnopqrstuvwxyz"
    ].each { |text| expect(redaction.text(text)).to eq(text) }
  end

  it "drops query, fragment and userinfo from a URL label, including unparsable URLs" do
    expect(redaction.url("https://u:p@h.example/p?key=1#f")).to eq("https://h.example/p")
    expect(redaction.url("ht!tp://u:p@broken url[?key=1")).not_to match(/u:p|key=1/)
  end

  it "formats an exception as scrubbed, valid UTF-8 within a byte limit" do
    error = RuntimeError.new("x#{'é' * 700} key=#{gemini_key}")
    formatted = redaction.error(error, limit: 1_000)
    expect(formatted).to start_with("RuntimeError: x")
    expect(formatted).to be_valid_encoding
    expect(formatted.bytesize).to be <= 1_000
    expect(redaction.error(RuntimeError.new("key=#{gemini_key}"))).to eq("RuntimeError: key=[REDACTED]")
  end

  it "never raises on text in an invalid or non-ASCII-compatible encoding" do
    invalid = "key=#{gemini_key} \xFF\xFE".dup.force_encoding(Encoding::UTF_8)

    expect(redaction.text(invalid)).to eq("key=[REDACTED] \uFFFD\uFFFD")
    expect(redaction.secret?(("\xFF" * 20).dup.force_encoding(Encoding::UTF_8))).to be(false)
    expect(redaction.text("token=#{'a' * 20}".encode(Encoding::UTF_16LE))).to eq("token=[REDACTED]")
  end
end
