# frozen_string_literal: true

require "spec_helper"
require "active_record"

RSpec.describe "Ingestion last_error redaction" do
  before do
    establish_database_connection!
    create_lct_tables!
    [LlmCostTracker::Call, LlmCostTracker::CallLineItem, LlmCostTracker::CallTag, LlmCostTracker::CallRollup,
     LlmCostTracker::Ingestion::InboxEntry, LlmCostTracker::Ingestion::Lease].each(&:reset_column_information)
    LlmCostTracker.configuration.ingestion.mode = :async
    allow(LlmCostTracker::Ingestion::Worker).to receive(:ensure_started)
    allow(LlmCostTracker::Logging).to receive(:warn)
    LlmCostTracker.track(provider: :openai, model: "gpt-4o", tokens: { input_tokens: 1, output_tokens: 0 })
  end

  after do
    LlmCostTracker::Ingestion::InboxEntry.delete_all
    LlmCostTracker::Ingestion::Worker.shutdown!
    disconnect_database!
  end

  it "does not store credentials that a database error message echoes back" do
    allow(LlmCostTracker::Ledger::Store).to receive(:persist_records).and_raise(
      ActiveRecord::StatementInvalid,
      "PG::UntranslatableCharacter: ERROR:  unsupported Unicode escape sequence\n" \
      "CONTEXT:  JSON data, line 1: ...proxy.example/v1?token=SEKRETSEKRETSEKRET\",\"note\":\"x\\u0000..."
    )

    LlmCostTracker::Ingestion::Worker.ingest_once(require_lease: false)

    last_error = LlmCostTracker::Ingestion::InboxEntry.first.last_error
    expect(last_error).to include("UntranslatableCharacter")
    expect(last_error).not_to include("SEKRET")
  end

  it "stores a truncated multibyte message as valid UTF-8" do
    allow(LlmCostTracker::Ledger::Store).to receive(:persist_records).and_raise("x#{'é' * 700}")

    LlmCostTracker::Ingestion::Worker.ingest_once(require_lease: false)

    last_error = LlmCostTracker::Ingestion::InboxEntry.first.last_error
    expect(last_error).to be_present
    expect(last_error).to be_valid_encoding
    expect(last_error.bytesize).to be <= 1_000
  end
end
