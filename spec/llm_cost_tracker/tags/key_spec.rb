# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/tags/key"

RSpec.describe LlmCostTracker::Tags::Key do
  describe ".validate!" do
    it "accepts a key with allowed characters" do
      expect(described_class.validate!("feature.user_id-1")).to eq("feature.user_id-1")
    end

    it "rejects invalid characters" do
      expect { described_class.validate!("feature key") }
        .to raise_error(ArgumentError, /invalid tag key/)
    end

    it "rejects keys exceeding the bytesize cap" do
      key = "a" * (described_class::MAX_BYTESIZE + 1)

      expect { described_class.validate!(key) }
        .to raise_error(ArgumentError, /tag key exceeds #{described_class::MAX_BYTESIZE} bytes/)
    end

    it "honours a custom error class" do
      expect { described_class.validate!("bad key", error_class: LlmCostTracker::Error) }
        .to raise_error(LlmCostTracker::Error)
    end
  end
end
