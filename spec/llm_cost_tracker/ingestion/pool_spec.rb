# frozen_string_literal: true

require "spec_helper"
require "active_record"

RSpec.describe LlmCostTracker::Ingestion::Pool do
  before do
    establish_database_connection!
    create_lct_tables!
    LlmCostTracker::Call.reset_column_information
    LlmCostTracker::Ingestion::InboxEntry.reset_column_information
    LlmCostTracker.configuration.ingestion.mode = :async
    allow(LlmCostTracker::Ingestion::Worker).to receive(:ensure_started)
  end

  after do
    described_class.instance_variable_get(:@pool)&.disconnect!
    described_class.instance_variable_set(:@pool, nil)
    described_class.instance_variable_set(:@handler, nil)
    disconnect_database!
  end

  it "lends a connection from a pool separate from ActiveRecord::Base.connection_pool" do
    described_class.with_connection do |connection|
      expect(connection).not_to equal(LlmCostTracker::Call.connection)
    end
    expect(described_class.pool).not_to equal(LlmCostTracker::Call.connection_pool)
  end

  it "persists the inbox row even when the caller transaction rolls back" do
    LlmCostTracker::Call.transaction do
      LlmCostTracker.track(
        provider: :openai, model: "gpt-4o",
        tokens: { input_tokens: 1_000, output_tokens: 0 }, tags: { feature: "chat" }
      )
      raise ActiveRecord::Rollback
    end

    expect(LlmCostTracker::Ingestion::InboxEntry.count).to eq(1)
  end

  it "builds the pool from the writing role when the first inbox write happens under the reading role" do
    primary = LlmCostTrackerDatabase.config
    ActiveRecord::Base.connects_to(database: { writing: primary, reading: primary.merge(replica: true) })
    track = -> { LlmCostTracker.track(provider: :openai, model: "gpt-4o", tokens: { input_tokens: 1_000 }) }

    ActiveRecord::Base.connected_to(role: :reading) { track.call }
    track.call

    expect(described_class.pool.db_config.configuration_hash).not_to include(:replica)
    expect(LlmCostTracker::Ingestion::InboxEntry.count).to eq(2)
  ensure
    ActiveRecord::Base.connection_handler.remove_connection_pool("ActiveRecord::Base", role: :reading)
    ActiveRecord::Base.establish_connection(primary)
  end

  it "honors ingestion_pool_size when configured" do
    LlmCostTracker.configuration.ingestion.pool_size = 3

    expect(described_class.pool.size).to eq(3)
  end
end
