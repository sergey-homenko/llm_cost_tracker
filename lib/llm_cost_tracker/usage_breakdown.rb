# frozen_string_literal: true

module LlmCostTracker
  UsageBreakdown = Data.define(
    :input_tokens,
    :cache_read_input_tokens,
    :cache_write_input_tokens,
    :output_tokens,
    :hidden_output_tokens
  ) do
    def self.build(input_tokens:, output_tokens:, cache_read_input_tokens: 0,
                   cache_write_input_tokens: 0, hidden_output_tokens: 0)
      new(
        input_tokens: input_tokens.to_i,
        cache_read_input_tokens: cache_read_input_tokens.to_i,
        cache_write_input_tokens: cache_write_input_tokens.to_i,
        output_tokens: output_tokens.to_i,
        hidden_output_tokens: hidden_output_tokens.to_i
      )
    end

    def total_tokens
      input_tokens + cache_read_input_tokens + cache_write_input_tokens + output_tokens
    end

    def to_h
      super.merge(total_tokens: total_tokens).compact
    end
  end
end
