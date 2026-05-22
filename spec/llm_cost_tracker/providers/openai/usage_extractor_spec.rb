# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/providers/openai/usage_extractor"

RSpec.describe LlmCostTracker::Providers::Openai::UsageExtractor do
  describe ".token_usage" do
    it "extracts core token counts from Responses-API key names" do
      result = described_class.token_usage({ input_tokens: 200, output_tokens: 80, total_tokens: 280 })

      expect(result.input_tokens).to eq(200)
      expect(result.output_tokens).to eq(80)
      expect(result.total_tokens).to eq(280)
    end

    it "extracts core token counts from Chat-Completions-API key names" do
      result = described_class.token_usage({ prompt_tokens: 200, completion_tokens: 80, total_tokens: 280 })

      expect(result.input_tokens).to eq(200)
      expect(result.output_tokens).to eq(80)
    end

    it "subtracts cache_read, audio_input, and image_input from regular input_tokens" do
      usage = {
        input_tokens: 1_000,
        output_tokens: 100,
        input_tokens_details: { cached_tokens: 300, audio_tokens: 50, image_tokens: 100 }
      }
      result = described_class.token_usage(usage)

      expect(result.input_tokens).to eq(550)
      expect(result.cache_read_input_tokens).to eq(300)
      expect(result.audio_input_tokens).to eq(50)
      expect(result.image_input_tokens).to eq(100)
    end

    it "reads cache_read from prompt_tokens_details for Chat-Completions responses" do
      usage = { prompt_tokens: 500, completion_tokens: 0, prompt_tokens_details: { cached_tokens: 100 } }
      result = described_class.token_usage(usage)

      expect(result.cache_read_input_tokens).to eq(100)
      expect(result.input_tokens).to eq(400)
    end

    it "uses output_tokens_details image_tokens for the image/text split when present" do
      usage = { input_tokens: 0, output_tokens: 100, output_tokens_details: { image_tokens: 60, text_tokens: 40 } }
      result = described_class.token_usage(usage)

      expect(result.image_output_tokens).to eq(60)
      expect(result.output_tokens).to eq(40)
    end

    it "infers text output as the remainder when only image_tokens detail is provided" do
      usage = { input_tokens: 0, output_tokens: 100, output_tokens_details: { image_tokens: 60 } }
      result = described_class.token_usage(usage)

      expect(result.image_output_tokens).to eq(60)
      expect(result.output_tokens).to eq(40)
    end

    it "routes all output to image_output_tokens for gpt-image-* models when no detail split is given" do
      result = described_class.token_usage({ input_tokens: 0, output_tokens: 100 }, model: "gpt-image-1")

      expect(result.image_output_tokens).to eq(100)
      expect(result.output_tokens).to eq(0)
    end

    it "leaves output unsplit for non-image models when no detail split is given" do
      result = described_class.token_usage({ input_tokens: 0, output_tokens: 100 }, model: "gpt-4o")

      expect(result.image_output_tokens).to eq(0)
      expect(result.output_tokens).to eq(100)
    end

    it "subtracts audio_output from the unsplit output remainder" do
      usage = { input_tokens: 0, output_tokens: 100, output_tokens_details: { audio_tokens: 30 } }
      result = described_class.token_usage(usage)

      expect(result.audio_output_tokens).to eq(30)
      expect(result.output_tokens).to eq(70)
    end

    it "captures reasoning_tokens from output_tokens_details as hidden_output_tokens" do
      usage = { input_tokens: 0, output_tokens: 100, output_tokens_details: { reasoning_tokens: 20 } }
      result = described_class.token_usage(usage)

      expect(result.hidden_output_tokens).to eq(20)
    end

    it "honors the provider's total_tokens when greater than the per-bucket sum" do
      usage = { input_tokens: 100, output_tokens: 50, total_tokens: 200 }
      result = described_class.token_usage(usage)

      expect(result.total_tokens).to eq(200)
    end
  end

  describe ".split_output" do
    it "routes everything to image when default_to_image is true and no detail split arrives" do
      expect(described_class.split_output(
               output_tokens: 100, image_output_details: 0, text_output_details: 0,
               audio_output: 0, default_to_image: true
             )).to eq([100, 0])
    end

    it "routes everything to text when default_to_image is false and no detail split arrives" do
      expect(described_class.split_output(
               output_tokens: 100, image_output_details: 0, text_output_details: 0,
               audio_output: 0, default_to_image: false
             )).to eq([0, 100])
    end

    it "honors the detail-provided image split and recomputes text from the remainder" do
      expect(described_class.split_output(
               output_tokens: 100, image_output_details: 60, text_output_details: 0,
               audio_output: 10, default_to_image: false
             )).to eq([60, 30])
    end
  end

  describe "detail extractors" do
    it "prefer input_tokens_details over the older containers" do
      usage = {
        input_tokens_details: { cached_tokens: 1 },
        input_token_details: { cached_tokens: 2 },
        prompt_tokens_details: { cached_tokens: 3 }
      }
      expect(described_class.cache_read_input_tokens(usage)).to eq(1)
    end

    it "fall back to prompt_tokens_details when modern containers are absent" do
      expect(described_class.cache_read_input_tokens({ prompt_tokens_details: { cached_tokens: 7 } })).to eq(7)
    end

    it "return 0 when no detail container carries the key" do
      expect(described_class.cache_read_input_tokens({ input_tokens_details: { audio_tokens: 1 } })).to eq(0)
    end
  end
end
