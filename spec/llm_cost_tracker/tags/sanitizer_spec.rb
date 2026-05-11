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

  it "keeps the most recently added tags when the count cap is exceeded" do
    tags = described_class.call({ first: "1", second: "2", third: "3" }, config: config)

    expect(tags).to eq(second: "2", third: "3")
  end

  it "redacts a secret-shaped value before truncation so a small max_tag_value_bytesize cannot leave the leading bytes of the secret in the tag" do
    tiny_config = instance_double(
      LlmCostTracker::Configuration,
      max_tag_count: 10,
      max_tag_value_bytesize: 6,
      redacted_tag_keys: []
    )

    tags = described_class.call({ feature: "sk-proj-A1B2C3D4E5F6G7H8I9J0" }, config: tiny_config)

    expect(tags[:feature]).to eq("[REDACTED]")
    expect(tags[:feature]).not_to include("sk-pr")
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

    it "redacts GitHub classic personal access tokens regardless of the tag key" do
      tags = described_class.call(
        { user: "ghp_1234567890ABCDEFGHIJKLMNOPQRSTUVwxyz" },
        config: config
      )

      expect(tags[:user]).to eq("[REDACTED]")
    end

    it "redacts GitHub fine-grained personal access tokens regardless of the tag key" do
      tags = described_class.call(
        { auth: "github_pat_11AAAAAABBBBBBCCCCCCDDDDD" },
        config: config
      )

      expect(tags[:auth]).to eq("[REDACTED]")
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

    it "redacts secrets nested inside Hash and Array tag values" do
      tags = described_class.call(
        { context: { headers: { authorization: "Bearer abcdef0123456789ABCDEFGH" } } },
        config: config
      )

      expect(tags[:context][:headers][:authorization]).to eq("[REDACTED]")
    end

    it "redacts secrets buried in Array leaves" do
      tags = described_class.call(
        { trail: ["clean-id", "sk-proj-A1B2C3D4E5F6G7H8I9J0"] },
        config: config
      )

      expect(tags[:trail]).to eq(["clean-id", "[REDACTED]"])
    end

    it "keeps the redaction marker intact inside nested values even when max_tag_value_bytesize is smaller than '[REDACTED]'" do
      tiny_config = instance_double(
        LlmCostTracker::Configuration,
        max_tag_count: 10,
        max_tag_value_bytesize: 5,
        redacted_tag_keys: []
      )
      tags = described_class.call(
        { trail: ["sk-proj-A1B2C3D4E5F6G7H8I9J0"] },
        config: tiny_config
      )

      expect(tags[:trail]).to eq(["[REDACTED]"])
    end

    it "redacts Slack tokens regardless of the tag key" do
      tags = described_class.call({ note: "xoxb-123456789012-abcdefghijkl" }, config: config)

      expect(tags[:note]).to eq("[REDACTED]")
    end

    it "redacts Stripe live keys regardless of the tag key" do
      synthetic_stripe_value = ["sk", "live", "synthetictesttokenforsanitizerregex"].join("_")
      tags = described_class.call({ note: synthetic_stripe_value }, config: config)

      expect(tags[:note]).to eq("[REDACTED]")
    end

    it "redacts Google API keys regardless of the tag key" do
      tags = described_class.call({ note: "AIzaSyDEXAMPLEgoogleapikey1234567890abc" }, config: config)

      expect(tags[:note]).to eq("[REDACTED]")
    end
  end
end
