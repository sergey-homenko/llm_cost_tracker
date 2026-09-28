# frozen_string_literal: true

module AccountingCases
  define_case "track openai: gpt-4o with cache reads" do
    LlmCostTracker.track(provider: "openai", model: "gpt-4o",
                         tokens: { input_tokens: 1000, output_tokens: 200, cache_read_input_tokens: 300 })
  end

  define_case "track openai: gpt-5.4 priority mode" do
    LlmCostTracker.track(provider: "openai", model: "gpt-5.4", pricing_mode: "priority",
                         tokens: { input_tokens: 10_000, output_tokens: 1000 })
  end

  define_case "track openai: gpt-5.4 batch_data_residency mode with cache reads" do
    LlmCostTracker.track(provider: "openai", model: "gpt-5.4", pricing_mode: "batch_data_residency",
                         tokens: { input_tokens: 10_000, output_tokens: 1000, cache_read_input_tokens: 5000 })
  end

  define_case "track openai: gpt-5.5-pro long context" do
    LlmCostTracker.track(provider: "openai", model: "gpt-5.5-pro",
                         tokens: { input_tokens: 300_000, output_tokens: 10_000 })
  end

  define_case "track openai: gpt-5.5-pro long context in flex mode" do
    LlmCostTracker.track(provider: "openai", model: "gpt-5.5-pro", pricing_mode: "flex",
                         tokens: { input_tokens: 300_000, output_tokens: 10_000 })
  end

  define_case "track openai: gpt-5.5-pro long context in batch mode" do
    LlmCostTracker.track(provider: "openai", model: "gpt-5.5-pro", pricing_mode: "batch",
                         tokens: { input_tokens: 300_000, output_tokens: 10_000 })
  end

  define_case "track openai: gpt-5.5-pro long context in data_residency mode" do
    LlmCostTracker.track(provider: "openai", model: "gpt-5.5-pro", pricing_mode: "data_residency",
                         tokens: { input_tokens: 300_000, output_tokens: 10_000 })
  end

  define_case "track openai: gpt-5.4 long context with cache reads in flex mode" do
    LlmCostTracker.track(provider: "openai", model: "gpt-5.4", pricing_mode: "flex",
                         tokens: { input_tokens: 100_000, cache_read_input_tokens: 200_000, output_tokens: 2000 })
  end

  define_case "track openai: gpt-5.4 long context with cache reads in batch mode" do
    LlmCostTracker.track(provider: "openai", model: "gpt-5.4", pricing_mode: "batch",
                         tokens: { input_tokens: 100_000, cache_read_input_tokens: 200_000, output_tokens: 2000 })
  end

  define_case "track openai: gpt-5.4 long context with cache reads in batch_data_residency mode" do
    LlmCostTracker.track(provider: "openai", model: "gpt-5.4", pricing_mode: "batch_data_residency",
                         tokens: { input_tokens: 100_000, cache_read_input_tokens: 200_000, output_tokens: 2000 })
  end

  define_case "track gemini: 2.5-flash image and audio input" do
    LlmCostTracker.track(provider: "gemini", model: "gemini-2.5-flash",
                         tokens: { input_tokens: 100, image_input_tokens: 1290, audio_input_tokens: 3200,
                                   output_tokens: 400 })
  end

  define_case "track gemini: 2.0-flash-lite image and audio input" do
    LlmCostTracker.track(provider: "gemini", model: "gemini-2.0-flash-lite",
                         tokens: { input_tokens: 100, image_input_tokens: 1290, audio_input_tokens: 3200,
                                   output_tokens: 400 })
  end

  define_case "track gemini: 2.5-flash image input in flex mode" do
    LlmCostTracker.track(provider: "gemini", model: "gemini-2.5-flash", pricing_mode: "flex",
                         tokens: { input_tokens: 100, image_input_tokens: 1290, output_tokens: 400 })
  end

  define_case "track gemini: 2.5-flash-image image output" do
    LlmCostTracker.track(provider: "gemini", model: "gemini-2.5-flash-image",
                         tokens: { input_tokens: 12, image_output_tokens: 1290, output_tokens: 0 })
  end

  define_case "track gemini: 3-pro-image text and image output" do
    LlmCostTracker.track(provider: "gemini", model: "gemini-3-pro-image",
                         tokens: { input_tokens: 20, image_input_tokens: 560, image_output_tokens: 1120,
                                   output_tokens: 200 })
  end

  define_case "track gemini: 2.5-pro long context with image and audio input" do
    LlmCostTracker.track(provider: "gemini", model: "gemini-2.5-pro",
                         tokens: { input_tokens: 200_000, image_input_tokens: 30_000, audio_input_tokens: 20_000,
                                   output_tokens: 3000 })
  end

  define_case "track anthropic: sonnet-4-5 batch mode with 5m and 1h cache writes" do
    LlmCostTracker.track(provider: "anthropic", model: "claude-sonnet-4-5", pricing_mode: "batch",
                         tokens: { input_tokens: 1000, output_tokens: 500, cache_read_input_tokens: 2000,
                                   cache_write_input_tokens: 300, cache_write_extended_input_tokens: 400 })
  end

  define_case "track anthropic: sonnet-4-6 batch_data_residency mode" do
    LlmCostTracker.track(provider: "anthropic", model: "claude-sonnet-4-6", pricing_mode: "batch_data_residency",
                         tokens: { input_tokens: 1000, output_tokens: 500, cache_read_input_tokens: 20_000 })
  end

  define_case "track openai: unknown model" do
    LlmCostTracker.track(provider: "openai", model: "gpt-unknown-x", tokens: { input_tokens: 100, output_tokens: 10 })
  end

  define_case "track openai: web search service line" do
    LlmCostTracker.track(provider: "openai", model: "gpt-4o", tokens: { input_tokens: 1000, output_tokens: 100 },
                         service_line_items: [{ dimension_key: "web_search_request", quantity: 3,
                                                cost_status: "unknown", pricing_basis: "provider_usage" }])
  end

  define_case "track openai: whisper-1 transcription minutes service line" do
    LlmCostTracker.track(provider: "openai", model: "whisper-1", tokens: { input_tokens: 0, output_tokens: 0 },
                         service_line_items: [{ dimension_key: "transcription_minute", quantity: 3,
                                                cost_status: "unknown", pricing_basis: "provider_usage" }])
  end

  define_case "track openai: chat-latest, gpt-5.6-cyber, gpt-rosalind-research and gpt-image-2.5-sunburst" do
    LlmCostTracker.track(provider: "openai", model: "chat-latest", tokens: { input_tokens: 1000, output_tokens: 100 })
    LlmCostTracker.track(provider: "openai", model: "gpt-5.6-cyber", tokens: { input_tokens: 1000, output_tokens: 100 })
    LlmCostTracker.track(provider: "openai", model: "gpt-rosalind-research",
                         tokens: { input_tokens: 1000, output_tokens: 100 })
    LlmCostTracker.track(provider: "openai", model: "gpt-image-2.5-sunburst",
                         tokens: { input_tokens: 50, image_input_tokens: 100, image_output_tokens: 1056 })
  end

  define_case "track openrouter: listed model without billed cost" do
    LlmCostTracker.track(provider: "openrouter", model: "openai/gpt-4o",
                         tokens: { input_tokens: 3000, output_tokens: 500 })
  end

  define_case "track groq: on_demand mode with cache reads" do
    LlmCostTracker.track(provider: "groq", model: "openai/gpt-oss-120b", pricing_mode: "on_demand",
                         tokens: { input_tokens: 10_000, output_tokens: 1000, cache_read_input_tokens: 2000 })
  end

  define_case "track openai: pricing modes as symbol, padded uppercase, dashed and standard" do
    LlmCostTracker.track(provider: "openai", model: "gpt-5.4", pricing_mode: :Priority,
                         tokens: { input_tokens: 1000, output_tokens: 100 })
    LlmCostTracker.track(provider: "openai", model: "gpt-5.4", pricing_mode: " FLEX ",
                         tokens: { input_tokens: 1000, output_tokens: 100 })
    LlmCostTracker.track(provider: "openai", model: "gpt-5.4", pricing_mode: "batch-data_residency",
                         tokens: { input_tokens: 1000, output_tokens: 100 })
    LlmCostTracker.track(provider: "openai", model: "gpt-5.4", pricing_mode: "standard",
                         tokens: { input_tokens: 1000, output_tokens: 100 })
  end

  define_case "track anthropic: batch mode with a web search service line" do
    LlmCostTracker.track(provider: "anthropic", model: "claude-sonnet-4-5", pricing_mode: "batch",
                         tokens: { input_tokens: 1000, output_tokens: 100 },
                         service_line_items: [{ dimension_key: "web_search_request", quantity: 2,
                                                cost_status: "unknown", pricing_basis: "provider_usage" }])
  end

  define_case "track openai: pre-priced custom service line" do
    LlmCostTracker.track(provider: "openai", model: "gpt-4o", tokens: { input_tokens: 1000, output_tokens: 100 },
                         service_line_items: [{ dimension_key: "web_search_request", quantity: 1, rate_amount: 0.02,
                                                cost: 0.02, pricing_basis: "custom", price_source: "manual" }])
  end

  define_case "track openrouter: billed request service line" do
    LlmCostTracker.track(provider: "openrouter", model: "openai/gpt-4o",
                         tokens: { input_tokens: 3000, output_tokens: 500 },
                         service_line_items: [{ dimension_key: "billed_request", quantity: 1, rate_amount: 0.0123,
                                                cost: 0.0123, pricing_basis: "provider_usage",
                                                price_source: "provider_response" }])
  end

  define_case "track openai: zero tokens on a listed model" do
    LlmCostTracker.track(provider: "openai", model: "gpt-4o", tokens: { input_tokens: 0, output_tokens: 0 })
  end

  define_case "track openai: image generation call service line" do
    LlmCostTracker.track(provider: "openai", model: "gpt-5.5", tokens: { input_tokens: 2000, output_tokens: 200 },
                         service_line_items: [{ dimension_key: "image_generation_call", quantity: 1,
                                                cost_status: "unknown", pricing_basis: "provider_usage" }])
  end
end
