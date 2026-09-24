# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Tags::Sanitizer do
  def build_config(max_tag_count:, max_tag_value_bytesize:, redacted_tag_keys:)
    tags = instance_double(
      LlmCostTracker::Configuration::Tags,
      max_count: max_tag_count,
      max_value_bytesize: max_tag_value_bytesize,
      redacted_keys: redacted_tag_keys,
      normalized_redacted_keys: redacted_tag_keys.map { |key| described_class.normalized_key(key) }
    )
    instance_double(LlmCostTracker::Configuration, tags: tags)
  end

  let(:config) { build_config(max_tag_count: 2, max_tag_value_bytesize: 4, redacted_tag_keys: %w[api_key access_token]) }

  it "keeps the most recently added tags when the count cap is exceeded" do
    tags = described_class.call({ first: "1", second: "2", third: "3" }, config: config)

    expect(tags).to eq(second: "2", third: "3")
  end

  it "skips tag keys that fail Tags::Key validation so storage doesn't write a row the dashboard read would reject" do
    allow(LlmCostTracker::Logging).to receive(:warn)

    tags = described_class.call({ "weird key!" => "v", valid_key: "v" }, config: config)

    expect(tags).to eq(valid_key: "v")
    expect(LlmCostTracker::Logging).to have_received(:warn).with(include("weird key!"))
  end

  it "redacts a secret-shaped value before truncation so a small max_tag_value_bytesize cannot leave the leading bytes of the secret in the tag" do
    tiny_config = build_config(max_tag_count: 10, max_tag_value_bytesize: 6, redacted_tag_keys: [])

    tags = described_class.call({ feature: "sk-proj-A1B2C3D4E5F6G7H8I9J0" }, config: tiny_config)

    expect(tags[:feature]).to eq("[REDACTED]")
    expect(tags[:feature]).not_to include("sk-pr")
  end

  it "replaces invalid UTF-8 and removes NUL bytes, including nested values, so with_tags does not raise" do
    invalid = "\xFF\xFE" * 10

    expect(described_class.call({ q: invalid, h: { k: ["x\u0000"] } })).to eq(q: "\uFFFD" * 20, h: { k: ["x"] })
    expect(LlmCostTracker.with_tags(q: invalid) { :ran }).to eq(:ran)
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
    let(:config) { build_config(max_tag_count: 10, max_tag_value_bytesize: 4096, redacted_tag_keys: %w[api_key]) }

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
      tiny_config = build_config(max_tag_count: 10, max_tag_value_bytesize: 5, redacted_tag_keys: [])
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

  describe ".cap" do
    let(:config) { build_config(max_tag_count: 3, max_tag_value_bytesize: 4096, redacted_tag_keys: []) }

    it "returns the input unchanged when its size is within max_tag_count" do
      tags = { a: 1, b: 2 }
      expect(described_class.cap(tags, config: config)).to equal(tags)
    end

    it "keeps the last max_tag_count entries when the union overflows" do
      result = described_class.cap({ a: 1, b: 2, c: 3, d: 4, e: 5 }, config: config)
      expect(result).to eq(c: 3, d: 4, e: 5)
    end
  end

  describe "secrets inside longer values" do
    let(:gemini_key) { "AIzaSy#{'A1b2C3d4' * 4}x" }

    it "scrubs a Gemini key embedded in a URL tag value but keeps the rest of the URL" do
      url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?alt=sse&key=#{gemini_key}"

      value = described_class.call({ upstream: url })[:upstream]

      expect(value).not_to include(gemini_key)
      expect(value).to include("generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash")
      expect(value).to include("alt=sse")
    end

    it "scrubs key=, api-key= and sig= fragments and embedded provider tokens inside longer values" do
      tags = described_class.call(
        {
        note: "retry key=#{gemini_key}",
        azure: "https://r.openai.azure.com/openai/x?api-version=2024-10-21&api-key=abcdef0123456789&sig=Zm9vYmFy",
        openai: "calling with sk-proj-#{'a' * 24} failed",
        proxy: "https://svc:hunter2hunter2@proxy.internal/v1" }
      )

      expect(tags.values.join(" ")).not_to match(/#{gemini_key}|abcdef0123456789|Zm9vYmFy|sk-proj-a|hunter2/)
      expect(tags[:azure]).to include("api-version=2024-10-21")
    end

    it "scrubs credentials inside non-string values such as a request URI or an exception" do
      uri = URI("https://generativelanguage.googleapis.com/v1beta/models/m:generateContent?key=#{gemini_key}")
      error = RuntimeError.new("the server responded with status 429 for POST https://r.example/x?api-key=#{'f' * 32}")

      tags = described_class.call({ endpoint: uri, error: error, note: :"retry key=#{gemini_key}" })

      expect(tags.values.map(&:to_s).join(" ")).not_to match(/#{gemini_key}|#{'f' * 32}/)
      expect(tags[:endpoint]).to include("generativelanguage.googleapis.com/v1beta/models/m:generateContent")
    end

    it "scrubs an oversized value within the part that is kept" do
      value = "retry key=#{gemini_key} #{'x' * 200_000}"

      scrubbed = described_class.call({ note: value })[:note]

      expect(scrubbed).not_to include(gemini_key)
      expect(scrubbed.bytesize).to be <= LlmCostTracker.configuration.tags.max_value_bytesize
    end

    it "redacts a non-string value that is itself a key and keeps other non-string values" do
      tags = described_class.call({ symbol_key: :"#{gemini_key}", count: 42, flag: true })

      expect(tags).to eq(symbol_key: "[REDACTED]", count: 42, flag: true)
    end

    it "leaves ordinary URLs and key-value strings alone" do
      tags = described_class.call(
        { referrer: "https://app.example.com/search?q=shoes&page=2",
        label: "error_code=429 env=prod",
        model: "gpt-4o" }
      )

      expect(tags).to eq(referrer: "https://app.example.com/search?q=shoes&page=2", label: "error_code=429 env=prod",
                         model: "gpt-4o")
    end
  end
end
