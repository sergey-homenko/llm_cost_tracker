# frozen_string_literal: true

require "spec_helper"
require_relative "../dummy/config/environment"

RSpec.describe LlmCostTracker::ProviderInvoice do
  include_context "with mounted llm cost tracker engine"
  include_context "with reconciliation enabled"

  it "upcases the currency before validation so a direct ProviderInvoice.create!(currency: 'usd') stores the canonical 'USD' shape that Reconciliation.diff queries with" do
    invoice = described_class.create!(
      source: "openai", external_id: "openai:upper-test",
      period_start: Date.new(2026, 5, 1), period_end: Date.new(2026, 5, 31),
      billed_amount: BigDecimal("1.00"), currency: "usd",
      metadata: { "provider" => "openai" },
      imported_at: Time.now.utc
    )

    expect(invoice.currency).to eq("USD")
  end

  it "leaves an explicitly blank currency alone instead of coercing it to an empty string upcase no-op (downstream NOT NULL constraint still fires the meaningful error)" do
    invoice = described_class.new(currency: nil)
    invoice.valid?

    expect(invoice.currency).to be_nil
  end
end
