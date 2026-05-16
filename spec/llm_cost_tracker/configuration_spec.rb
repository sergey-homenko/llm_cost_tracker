# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Configuration do
  let(:config) { described_class.new }

  describe "ingestion enum" do
    it "defaults to :inline" do
      expect(config.ingestion).to eq(:inline)
    end

    it "accepts :async" do
      config.ingestion = :async
      expect(config.ingestion).to eq(:async)
    end

    it "raises for unknown values" do
      expect { config.ingestion = :bogus }.to raise_error(LlmCostTracker::Error, /Unknown ingestion/)
    end

    it "normalizes nil back to :inline" do
      config.ingestion = :async
      config.ingestion = nil
      expect(config.ingestion).to eq(:inline)
    end
  end

  describe "config.durable_ingestion= (deprecated)" do
    it "maps true to :async with a deprecation warning" do
      expect { config.durable_ingestion = true }
        .to output(/durable_ingestion= is deprecated/).to_stderr
      expect(config.ingestion).to eq(:async)
    end

    it "maps false to :inline with a deprecation warning" do
      config.ingestion = :async
      expect { config.durable_ingestion = false }
        .to output(/durable_ingestion= is deprecated/).to_stderr
      expect(config.ingestion).to eq(:inline)
    end
  end

  describe "config.durable_ingestion reader (deprecated)" do
    it "returns true when ingestion is :async" do
      config.ingestion = :async
      result = nil
      expect { result = config.durable_ingestion }
        .to output(/config\.durable_ingestion is deprecated/).to_stderr
      expect(result).to be(true)
    end

    it "returns false when ingestion is :inline" do
      result = nil
      expect { result = config.durable_ingestion }
        .to output(/config\.durable_ingestion is deprecated/).to_stderr
      expect(result).to be(false)
    end
  end

  describe "config.durable_ingestion_pool_size (deprecated)" do
    it "writes through to ingestion_pool_size with a deprecation warning" do
      expect { config.durable_ingestion_pool_size = 5 }
        .to output(/durable_ingestion_pool_size= is deprecated/).to_stderr
      expect(config.ingestion_pool_size).to eq(5)
    end

    it "reads back through the deprecated accessor with a warning" do
      config.ingestion_pool_size = 7
      result = nil
      expect { result = config.durable_ingestion_pool_size }
        .to output(/durable_ingestion_pool_size is deprecated/).to_stderr
      expect(result).to eq(7)
    end
  end
end
