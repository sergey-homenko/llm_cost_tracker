# frozen_string_literal: true

require "spec_helper"
require "openai"
require "anthropic"
require "ruby_llm"
require_relative "golden"
require_relative "cases"
Dir[File.join(__dir__, "cases", "*.rb")].each { |file| require file }

RSpec.describe "Accounting golden cases" do
  include AccountingCases

  ledger_models = [LlmCostTracker::CallLineItem, LlmCostTracker::CallTag, LlmCostTracker::Call,
                   LlmCostTracker::CallRollup, LlmCostTracker::Ingestion::InboxEntry]

  before(:context) do
    establish_database_connection!
    create_lct_tables!
    ledger_models.each(&:reset_column_information)
  end

  after(:context) do
    AccountingGolden.write_updates(AccountingCases::ALL.map(&:name)) if AccountingGolden.update?
    disconnect_database!
  end

  before do
    stub_const("LlmCostTracker::Pricing::Registry::DEFAULT_PRICES_PATH", AccountingGolden::PRICES_PATH)
    LlmCostTracker::Pricing::Registry.reset!
    forget_retrieved_openai_batches
    allow(LlmCostTracker::Ingestion::Worker).to receive(:ensure_started)
    ledger_models.each(&:delete_all)
    RubyLLM.configure do |config|
      config.openai_api_key = "test-openai"
      config.anthropic_api_key = "test-anthropic"
      config.gemini_api_key = "test-gemini"
      config.openrouter_api_key = "test-openrouter"
      config.deepseek_api_key = "test-deepseek"
      config.xai_api_key = "test-xai"
    end
  end

  def capture(kase)
    LlmCostTracker.configure do |config|
      config.ingestion.mode = kase.async ? :async : :inline
      config.instrument(kase.instrument) if kase.instrument
      kase.configure&.call(config)
    end
    travel_to(AccountingGolden::CAPTURED_AT) { instance_exec(&kase.block) }
    LlmCostTracker::Ingestion::Worker.flush! if kase.async
    AccountingGolden.recorded
  end

  AccountingCases::ALL.each do |kase|
    it kase.name do
      skip kase.skip_on_ruby_llm_1 if kase.skip_on_ruby_llm_1 && AccountingGolden.ruby_llm_1?

      snapshot = capture(kase)
      if AccountingGolden.update?
        AccountingGolden.actual[kase.name] = snapshot
      else
        expect(AccountingGolden.expected).to have_key(kase.name), "no expectation; run with LCT_ACCOUNTING_UPDATE=1"
        differences = AccountingGolden.differences(AccountingGolden.expected[kase.name], snapshot)
        expect(differences).to be_empty, differences.join("\n")
      end
    end
  end

  it "has no expectations for undefined cases" do
    stale = AccountingGolden.expected.keys - AccountingCases::ALL.map(&:name)
    expect(stale).to be_empty, "expectations without a case: #{stale.join(', ')}" unless AccountingGolden.update?
  end
end
