# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Tags::Sanitizer do
  let(:config) do
    instance_double(
      LlmCostTracker::Configuration,
      max_tag_count: 2,
      max_tag_value_bytesize: 4,
      redacted_tag_keys: %w[api_key access_token]
    )
  end

  it "keeps only the configured number of tags" do
    tags = described_class.call({ first: "1", second: "2", third: "3" }, config: config)

    expect(tags).to eq(first: "1", second: "2")
  end

  it "redacts configured secret-like keys and common variants" do
    tags = described_class.call({ "openai.APIKey" => "sk-secret", accessToken: "token" }, config: config)

    expect(tags["openai.APIKey"]).to eq("[REDACTED]")
    expect(tags[:accessToken]).to eq("[REDACTED]")
  end

  it "truncates large values while preserving small values" do
    tags = described_class.call({ feature: "abcdef", user_id: 42 }, config: config)

    expect(tags[:feature]).to eq("abcd")
    expect(tags[:user_id]).to eq(42)
  end

  context "with a roomy byte budget" do
    let(:config) do
      instance_double(
        LlmCostTracker::Configuration,
        max_tag_count: 10,
        max_tag_value_bytesize: 4096,
        redacted_tag_keys: %w[api_key]
      )
    end

    it "redacts OpenAI-shaped secrets regardless of the tag key" do
      tags = described_class.call({ feature: "sk-proj-A1B2C3D4E5F6G7H8I9J0" }, config: config)

      expect(tags[:feature]).to eq("[REDACTED]")
    end

    it "redacts Anthropic admin keys regardless of the tag key" do
      tags = described_class.call(
        { note: "sk-ant-admin01-AAAAAAAAAAAAAAAAAAAAAA" },
        config: config
      )

      expect(tags[:note]).to eq("[REDACTED]")
    end

    it "redacts AWS access key ids regardless of the tag key" do
      tags = described_class.call({ context: "AKIAIOSFODNN7EXAMPLE" }, config: config)

      expect(tags[:context]).to eq("[REDACTED]")
    end

    it "redacts JWT-shaped values regardless of the tag key" do
      jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." \
            "eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
      tags = described_class.call({ session: jwt }, config: config)

      expect(tags[:session]).to eq("[REDACTED]")
    end

    it "redacts Bearer-token values regardless of the tag key" do
      tags = described_class.call(
        { trace: "Bearer abcdef0123456789ABCDEFGH" },
        config: config
      )

      expect(tags[:trace]).to eq("[REDACTED]")
    end

    it "leaves regular operational values alone even when they are long" do
      tags = described_class.call(
        { feature: "billing.invoice.preview", tenant: "acme-production-eu-west-1" },
        config: config
      )

      expect(tags[:feature]).to eq("billing.invoice.preview")
      expect(tags[:tenant]).to eq("acme-production-eu-west-1")
    end
  end
end
