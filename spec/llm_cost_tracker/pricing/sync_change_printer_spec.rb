# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "llm_cost_tracker/pricing/sync_change_printer"

RSpec.describe LlmCostTracker::Pricing::SyncChangePrinter do
  let(:io) { StringIO.new }

  describe ".call" do
    it "prints model changes with field-level from/to and skips service_charges section when absent" do
      described_class.call(
        { "openai/gpt-4o" => { "input" => { "from" => 0.5, "to" => 1.0 } } },
        output: io
      )

      output = io.string
      expect(output).to include("changed models: 1")
      expect(output).to include("- openai/gpt-4o")
      expect(output).to include("input: 0.5 -> 1.0")
      expect(output).not_to include("changed service charges")
    end

    it "prints service-charge changes as provider.component lines instead of treating them as model fields" do
      described_class.call(
        {
          "service_charges" => {
            "openai" => {
              "web_search_request" => { "from" => 25.0, "to" => 30.0 }
            }
          }
        },
        output: io
      )

      output = io.string
      expect(output).to include("changed models: 0")
      expect(output).to include("changed service charges: 1")
      expect(output).to include("- openai.web_search_request: 25.0 -> 30.0")
      expect(output).not_to match(/openai: nil -> nil/)
    end

    it "prints both model and service-charge changes side by side" do
      described_class.call(
        {
          "openai/gpt-4o" => { "input" => { "from" => 0.5, "to" => 1.0 } },
          "service_charges" => {
            "openai" => {
              "web_search_request" => { "from" => 25.0, "to" => 30.0 }
            }
          }
        },
        output: io
      )

      output = io.string
      expect(output).to include("changed models: 1")
      expect(output).to include("changed service charges: 1")
      expect(output).to include("- openai/gpt-4o")
      expect(output).to include("- openai.web_search_request: 25.0 -> 30.0")
    end

    it "is a no-op print of empty headers when there are no changes" do
      described_class.call({}, output: io)

      expect(io.string).to eq("  changed models: 0\n")
    end
  end
end
