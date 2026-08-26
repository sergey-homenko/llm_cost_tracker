# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/pricing/backfill"

RSpec.describe LlmCostTracker::Budget::PerTag do
  include_context "with mounted llm cost tracker engine"

  def repricing_for(total)
    instance_double(
      LlmCostTracker::Pricing::Calculation,
      cost: LlmCostTracker::Charges::Cost.new(components: {}, total: total, currency: "USD"),
      snapshot: { "currency" => "USD" },
      cost_status: LlmCostTracker::Charges::CostStatus::COMPLETE,
      priced_line_items: []
    )
  end

  def build_event(total_cost:, tags:, tracked_at: Time.now.utc)
    LlmCostTracker::Event.new(
      event_id: SecureRandom.uuid, provider: "openai", model: "gpt-4o",
      token_usage: LlmCostTracker::Usage::TokenUsage.build(input_tokens: 10, output_tokens: 5),
      pricing_mode: nil,
      cost: LlmCostTracker::Charges::Cost.new(components: {}, total: total_cost, currency: "USD"),
      tags: tags, latency_ms: nil, stream: false, usage_source: "manual",
      provider_response_id: nil, provider_project_id: nil, provider_api_key_id: nil,
      provider_workspace_id: nil, tracked_at: tracked_at,
      cost_status: LlmCostTracker::Charges::CostStatus::COMPLETE,
      pricing_snapshot: nil, line_items: []
    )
  end

  def spend(cost, tags:, tracked_at: Time.now.utc)
    event = build_event(total_cost: cost, tags: tags, tracked_at: tracked_at)
    LlmCostTracker::Ledger::Store.insert([event])
    event
  end

  def configure_per_tag(limits = { monthly: 10 }, behavior: nil, on_exceeded: nil, global_behavior: nil,
                        global_on_exceeded: nil, extra: nil)
    LlmCostTracker.configure do |config|
      entry = limits.dup
      entry[:behavior] = behavior if behavior
      entry[:on_exceeded] = on_exceeded if on_exceeded
      config.budgets.per_tag = { tenant_id: entry }.merge(extra || {})
      config.budgets.exceeded_behavior = global_behavior if global_behavior
      config.budgets.on_exceeded = global_on_exceeded if global_on_exceeded
    end
  end

  def tag_rows(key)
    LlmCostTracker::CallTag.where(key: key.to_s)
  end

  describe "the shipped default" do
    it "enforces nothing" do
      spend(1.0, tags: { tenant_id: 7 })

      expect(described_class.active?).to be(false)
      expect { LlmCostTracker::Budget.check!(spend(99.0, tags: { tenant_id: 7 })) }.not_to raise_error
    end
  end

  describe "recording" do
    it "copies the call cost and time onto every tag row" do
      event = spend(1.25, tags: { tenant_id: 42, feature: "chat" })

      rows = LlmCostTracker::CallTag.order(:key)
      expect(rows.map(&:key)).to eq(%w[feature tenant_id])
      expect(rows.map { |row| row.total_cost.to_f }).to all(eq(1.25))
      expect(rows.map(&:tracked_at)).to all(be_within(1).of(event.tracked_at))
    end

    it "resyncs tag costs when a call is repriced" do
      LlmCostTracker::Ledger::Store.insert([build_event(total_cost: nil, tags: { tenant_id: 42 })])
      call = LlmCostTracker::Call.last
      expect(tag_rows(:tenant_id).first.total_cost).to be_nil

      LlmCostTracker::Pricing::Backfill.send(:persist!, call, repricing_for(2.5))

      expect(tag_rows(:tenant_id).first.total_cost.to_f).to eq(2.5)
    end
  end

  describe "enforcement" do
    it "charges each tag value its own budget" do
      configure_per_tag({ monthly: 5 }, global_behavior: :raise)
      over = spend(6.0, tags: { tenant_id: 42 })
      under = spend(1.0, tags: { tenant_id: 43 })

      expect { LlmCostTracker::Budget.check!(over) }
        .to raise_error(LlmCostTracker::BudgetExceededError, /tenant_id=42/)
      expect { LlmCostTracker::Budget.check!(under) }.not_to raise_error
    end

    it "carries the scope in the exceeded payload" do
      payloads = []
      configure_per_tag({ monthly: 5 }, global_on_exceeded: ->(payload) { payloads << payload })
      spend(4.9, tags: { tenant_id: 42 })
      crossing = spend(0.5, tags: { tenant_id: 42 })

      LlmCostTracker::Budget.check!(crossing)

      expect(payloads.first).to include(budget_type: :monthly, scope: { key: "tenant_id", value: "42" })
    end

    it "matches an integer tag value against the stored string" do
      configure_per_tag({ monthly: 5 })
      spend(6.0, tags: { tenant_id: 42 })

      rule = described_class.rules_for({ "tenant_id" => 42 }).first

      expect(described_class.spend(rule.key, rule.value, :monthly, time: Time.now.utc)).to eq(BigDecimal("6.0"))
    end

    it "blocks the next call pre-send once the window is spent" do
      configure_per_tag({ monthly: 5 }, global_behavior: :block_requests)
      spend(6.0, tags: { tenant_id: 42 })

      LlmCostTracker::Tags::Context.with(tenant_id: 42) do
        expect { LlmCostTracker::Budget.enforce! }.to raise_error(LlmCostTracker::BudgetExceededError)
      end
      LlmCostTracker::Tags::Context.with(tenant_id: 43) do
        expect { LlmCostTracker::Budget.enforce! }.not_to raise_error
      end
    end

    it "counts only the window it is asked about" do
      configure_per_tag({ daily: 5 }, global_behavior: :raise)
      spend(6.0, tags: { tenant_id: 42 }, tracked_at: Time.now.utc - (3 * 86_400))
      today = spend(0.5, tags: { tenant_id: 42 })

      expect { LlmCostTracker::Budget.check!(today) }.not_to raise_error
    end
  end

  describe "per-rule behavior" do
    it "blocks the tag pre-send while the global policy only notifies" do
      configure_per_tag({ monthly: 5 }, behavior: :block_requests)
      spend(6.0, tags: { tenant_id: 42 })

      LlmCostTracker::Tags::Context.with(tenant_id: 42) do
        expect { LlmCostTracker::Budget.enforce! }.to raise_error(LlmCostTracker::BudgetExceededError, /tenant_id=42/)
      end
    end

    it "leaves the tag to notify while the global policy blocks" do
      notified = []
      configure_per_tag({ monthly: 5 }, behavior: :notify, on_exceeded: ->(payload) { notified << payload },
                                        global_behavior: :block_requests)
      spend(4.9, tags: { tenant_id: 42 })
      crossing = spend(0.5, tags: { tenant_id: 42 })

      LlmCostTracker::Tags::Context.with(tenant_id: 42) do
        expect { LlmCostTracker::Budget.enforce! }.not_to raise_error
      end
      expect { LlmCostTracker::Budget.check!(crossing) }.not_to raise_error
      expect(notified.first).to include(scope: { key: "tenant_id", value: "42" })
    end

    it "routes the tag callback separately from the global one" do
      scoped = []
      global = []
      configure_per_tag({ monthly: 5 }, on_exceeded: ->(payload) { scoped << payload },
                                        global_on_exceeded: ->(payload) { global << payload })
      spend(4.9, tags: { tenant_id: 42 })
      crossing = spend(0.5, tags: { tenant_id: 42 })

      LlmCostTracker::Budget.check!(crossing)

      expect(scoped.size).to eq(1)
      expect(global).to be_empty
    end
  end

  describe "several tags at once" do
    it "gives every declared tag its own budget and its own behavior" do
      notified = []
      configure_per_tag({ monthly: 5 }, behavior: :raise,
                        extra: { feature: { monthly: 100, behavior: :notify,
                                            on_exceeded: ->(payload) { notified << payload } } })
      over = spend(6.0, tags: { tenant_id: 42, feature: "chat" })

      expect { LlmCostTracker::Budget.check!(over) }
        .to raise_error(LlmCostTracker::BudgetExceededError, /tenant_id=42/)
      expect(notified).to be_empty
    end

    it "checks a second tag independently of the first" do
      notified = []
      configure_per_tag({ monthly: 1000 },
                        extra: { feature: { monthly: 2, on_exceeded: ->(payload) { notified << payload } } })
      spend(1.9, tags: { tenant_id: 42, feature: "chat" })
      crossing = spend(0.5, tags: { tenant_id: 42, feature: "chat" })

      LlmCostTracker::Budget.check!(crossing)

      expect(notified.map { |payload| payload[:scope] }).to eq([{ key: "feature", value: "chat" }])
    end
  end

  describe "pre-send cost" do
    it "queries only the rules that can actually block" do
      configure_per_tag({ monthly: 5 }, behavior: :notify,
                        extra: { feature: { monthly: 5, behavior: :block_requests } })
      spend(1.0, tags: { tenant_id: 42, feature: "chat" })
      queries = 0
      subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries += 1 if payload[:sql].include?("llm_cost_tracker_call_tags")
      end

      LlmCostTracker::Tags::Context.with(tenant_id: 42, feature: "chat") do
        LlmCostTracker::Budget.enforce!
      end
      ActiveSupport::Notifications.unsubscribe(subscription)

      expect(queries).to eq(1)
    end
  end

  describe ".backfill" do
    it "fills cost and time on rows recorded before the columns existed" do
      configure_per_tag
      event = spend(1.25, tags: { tenant_id: 42, feature: "chat" })
      LlmCostTracker::CallTag.update_all(total_cost: nil, tracked_at: nil)

      filled = described_class.backfill(batch_size: 1)

      expect(filled).to eq(2)
      rows = LlmCostTracker::CallTag.all
      expect(rows.map { |row| row.total_cost.to_f }).to all(eq(1.25))
      expect(rows.map(&:tracked_at)).to all(be_within(1).of(event.tracked_at))
    end

    it "leaves already filled rows alone and reports nothing to do" do
      configure_per_tag
      spend(1.0, tags: { tenant_id: 42 })

      expect(described_class.backfill).to eq(0)
    end
  end

  describe "a tag that cannot use the index" do
    it "warns once, naming the tag, when a budget read is slow" do
      configure_per_tag
      allow(LlmCostTracker::Logging).to receive(:warn)
      allow(described_class).to receive(:const_get).and_call_original
      stub_const("LlmCostTracker::Budget::PerTag::SLOW_READ_SECONDS", 0)

      2.times { described_class.spend("tenant_id", "42", :monthly, time: Time.now.utc) }

      expect(LlmCostTracker::Logging)
        .to have_received(:warn).with(/per_tag\["tenant_id"\] monthly read took/).once
    end
  end

  describe "with the columns missing" do
    before do
      ActiveRecord::Base.connection.remove_column(:llm_cost_tracker_call_tags, :total_cost)
      LlmCostTracker::CallTag.reset_column_information
    end

    after { LlmCostTracker::CallTag.reset_column_information }

    it "warns once, keeps recording calls, and enforces nothing" do
      configure_per_tag
      allow(LlmCostTracker::Logging).to receive(:warn)

      expect { spend(1.0, tags: { tenant_id: 42 }) }.to change(LlmCostTracker::Call, :count).by(1)
      expect(described_class.active?).to be(false)
      described_class.active?

      expect(LlmCostTracker::Logging).to have_received(:warn).with(/total_cost \/ tracked_at/).once
    end
  end
end
