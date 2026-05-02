# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Pricing::Sync::RegistryDiff do
  describe ".call" do
    it "reports mode-specific price changes" do
      current = {
        "openai/gpt-5" => {
          "input" => 2.5,
          "output" => 10.0,
          "batch_input" => 1.25,
          "priority_output" => 20.0,
          "_source" => "remote"
        }
      }
      updated = {
        "openai/gpt-5" => {
          "input" => 2.5,
          "output" => 10.0,
          "batch_input" => 0.75,
          "priority_output" => 20.0,
          "above_context_batch_input" => 5.0,
          "_source" => "remote"
        }
      }

      expect(described_class.call(current, updated)).to eq(
        "openai/gpt-5" => {
          "above_context_batch_input" => { "from" => nil, "to" => 5.0 },
          "batch_input" => { "from" => 1.25, "to" => 0.75 }
        }
      )
    end

    it "wraps invalid registry shapes" do
      expect do
        described_class.call("bad", {})
      end.to raise_error(LlmCostTracker::Error, /price table must be a hash of models/)
    end
  end
end
