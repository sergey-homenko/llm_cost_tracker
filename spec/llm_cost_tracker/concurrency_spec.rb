# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/capture/stream_collector"

RSpec.describe "concurrency", :aggregate_failures do
  describe LlmCostTracker::Capture::StreamCollector do
    before do
      allow(LlmCostTracker::Ingestion::Inbox).to receive(:save).and_return(true)
      allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_return(true)
    end

    it "records exactly one event when finish! races across many threads" do
      recorded = []
      subscription = ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
        recorded << payload
      end

      collector = described_class.new(provider: "openai", model: "gpt-4o")
      collector.usage(input_tokens: 1, output_tokens: 1)

      threads = Array.new(32) { Thread.new { collector.finish! } }
      threads.each(&:join)

      expect(recorded.size).to eq(1)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it "stays consistent when writers race with finish!" do
      recorded = []
      subscription = ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
        recorded << payload
      end

      collector = described_class.new(provider: "openai", model: "gpt-4o")
      collector.usage(input_tokens: 7, output_tokens: 3)
      write_errors = Queue.new

      writers = Array.new(16) do |i|
        Thread.new do
          20.times { |j| collector.event({ "i" => i, "j" => j }) }
        rescue FrozenError => e
          write_errors << e
        end
      end

      finisher = Thread.new { collector.finish! }

      (writers + [finisher]).each(&:join)

      expect(recorded.size).to eq(1)
      expect(recorded.first.dig(:token_usage, :input_tokens)).to eq(7)
      expect(recorded.first.dig(:token_usage, :output_tokens)).to eq(3)
      errors = []
      errors << write_errors.pop until write_errors.empty?
      expect(errors).to all(be_a(FrozenError))
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it "rejects writes after finish!" do
      collector = described_class.new(provider: "openai", model: "gpt-4o")
      collector.usage(input_tokens: 1, output_tokens: 1)
      collector.finish!

      expect { collector.event({ "late" => true }) }.to raise_error(FrozenError)
      expect { collector.usage(input_tokens: 2, output_tokens: 2) }.to raise_error(FrozenError)
      expect { collector.model = "gpt-4.1" }.to raise_error(FrozenError)
    end

    it "keeps stream-start tags when finish! runs in another thread" do
      recorded = Queue.new
      subscription = ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
        recorded << payload
      end

      collector = LlmCostTracker.with_tags(request_id: "req_123") do
        described_class.new(provider: "openai", model: "gpt-4o").tap do |stream|
          stream.usage(input_tokens: 1, output_tokens: 1)
        end
      end

      Thread.new do
        LlmCostTracker.with_tags(request_id: "wrong") { collector.finish! }
      end.join

      expect(recorded.pop[:tags]).to include(request_id: "req_123")
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    end
  end

  describe LlmCostTracker::Configuration do
    it "freezes mutable state after configure returns" do
      LlmCostTracker.configure do |config|
        config.default_tags = { env: "test" }
        config.pricing_overrides = { "foo" => { input: 1.0, output: 2.0 } }
        config.report_tag_breakdowns = %i[env]
        config.openai_compatible_providers = { "foo.example.com" => "foo" }
      end

      expect(LlmCostTracker.configuration.default_tags).to be_frozen
      expect(LlmCostTracker.configuration.pricing_overrides).to be_frozen
      expect(LlmCostTracker.configuration.report_tag_breakdowns).to be_frozen
      expect(LlmCostTracker.configuration.openai_compatible_providers).to be_frozen
    end

    it "rejects runtime mutation of shared hashes" do
      LlmCostTracker.configure { |config| config.default_tags = { env: "test" } }

      expect { LlmCostTracker.configuration.default_tags[:env] = "prod" }.to raise_error(FrozenError)
      expect { LlmCostTracker.configuration.openai_compatible_providers["x"] = "y" }.to raise_error(FrozenError)
    end

    it "validates report tag breakdown keys during configuration" do
      LlmCostTracker.configure { |config| config.report_tag_breakdowns = [:env, "feature.name"] }

      expect(LlmCostTracker.configuration.report_tag_breakdowns).to eq(%w[env feature.name])
    end

    it "rejects invalid report tag breakdown keys during configuration" do
      expect do
        LlmCostTracker.configure { |config| config.report_tag_breakdowns = ["feature; DROP"] }
      end.to raise_error(LlmCostTracker::Error, /invalid tag key/)
    end

    it "rejects runtime replacement of shared configuration" do
      LlmCostTracker.configure do |config|
        config.default_tags = { env: "test" }
        config.pricing_overrides = { "foo" => { input: 1.0 } }
        config.report_tag_breakdowns = %i[env]
        config.openai_compatible_providers = { "foo.example.com" => "foo" }
      end

      expect { LlmCostTracker.configuration.default_tags = { env: "prod" } }.to raise_error(FrozenError)
      expect { LlmCostTracker.configuration.pricing_overrides = {} }.to raise_error(FrozenError)
      expect { LlmCostTracker.configuration.report_tag_breakdowns = [] }.to raise_error(FrozenError)
      expect { LlmCostTracker.configuration.openai_compatible_providers = {} }.to raise_error(FrozenError)
    end

    it "rejects runtime replacement of shared scalar configuration" do
      LlmCostTracker.configure do |config|
        config.enabled = true
        config.on_budget_exceeded = ->(_data) {}
        config.monthly_budget = 10.0
        config.daily_budget = 5.0
        config.per_call_budget = 1.0
        config.log_level = :info
        config.prices_file = "/tmp/prices.json"
        config.budget_exceeded_behavior = :notify
        config.unknown_pricing_behavior = :warn
      end

      expect { LlmCostTracker.configuration.enabled = false }.to raise_error(FrozenError)
      expect { LlmCostTracker.configuration.on_budget_exceeded = nil }.to raise_error(FrozenError)
      expect { LlmCostTracker.configuration.monthly_budget = 20.0 }.to raise_error(FrozenError)
      expect { LlmCostTracker.configuration.daily_budget = 10.0 }.to raise_error(FrozenError)
      expect { LlmCostTracker.configuration.per_call_budget = 2.0 }.to raise_error(FrozenError)
      expect { LlmCostTracker.configuration.log_level = :debug }.to raise_error(FrozenError)
      expect { LlmCostTracker.configuration.prices_file = "/tmp/other.json" }.to raise_error(FrozenError)
      expect { LlmCostTracker.configuration.budget_exceeded_behavior = :raise }.to raise_error(FrozenError)
      expect { LlmCostTracker.configuration.unknown_pricing_behavior = :ignore }.to raise_error(FrozenError)
    end

    it "does not expose a public configuration writer" do
      expect do
        LlmCostTracker.configuration = LlmCostTracker::Configuration.new
      end.to raise_error(NoMethodError)
    end

    it "rejects repeated configuration after finalization" do
      LlmCostTracker.configure { |config| config.default_tags = { env: "test" } }

      expect do
        LlmCostTracker.configure { |config| config.default_tags = { env: "prod" } }
      end.to raise_error(LlmCostTracker::Error, /already configured/)

      expect(LlmCostTracker.configuration.default_tags).to eq(env: "test")
    end

    it "serves a consistent snapshot to many concurrent readers" do
      LlmCostTracker.configure do |config|
        config.default_tags = { env: "test", region: "eu" }
      end

      results = []
      mutex = Mutex.new
      threads = Array.new(16) do
        Thread.new do
          100.times do
            snapshot = LlmCostTracker.configuration.default_tags
            mutex.synchronize { results << snapshot }
          end
        end
      end
      threads.each(&:join)

      expect(results.uniq.size).to eq(1)
      expect(results.first).to eq(env: "test", region: "eu")
    end
  end

  describe LlmCostTracker::Tags::Context do
    before do
      allow(LlmCostTracker::Ingestion::Inbox).to receive(:save).and_return(true)
      allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_return(true)
    end

    it "keeps scoped tags isolated across threads" do
      recorded = Queue.new

      threads = Array.new(8) do |i|
        Thread.new do
          LlmCostTracker.with_tags(request_id: "req_#{i}") do
            event = LlmCostTracker::Tracker.record(
              event: LlmCostTracker::Event.build(
                provider: "openai",
                model: "gpt-4o",
                token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 1)
              )
            )
            recorded << event.tags[:request_id]
          end
        end
      end
      threads.each(&:join)

      values = []
      values << recorded.pop until recorded.empty?
      expect(values.sort).to eq(Array.new(8) { |i| "req_#{i}" })
    end

    it "keeps scoped tags isolated across fibers when Rails uses fiber isolation" do
      original_level = ActiveSupport::IsolatedExecutionState.isolation_level
      ActiveSupport::IsolatedExecutionState.isolation_level = :fiber
      recorded = []

      fiber_a = Fiber.new do
        LlmCostTracker.with_tags(request_id: "fiber_a") do
          Fiber.yield
          event = LlmCostTracker::Tracker.record(
            event: LlmCostTracker::Event.build(
              provider: "openai",
              model: "gpt-4o",
              token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 1)
            )
          )
          recorded << event.tags[:request_id]
        end
      end

      fiber_b = Fiber.new do
        LlmCostTracker.with_tags(request_id: "fiber_b") do
          event = LlmCostTracker::Tracker.record(
            event: LlmCostTracker::Event.build(
              provider: "openai",
              model: "gpt-4o",
              token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 1)
            )
          )
          recorded << event.tags[:request_id]
        end
      end

      fiber_a.resume
      fiber_b.resume
      fiber_a.resume

      expect(recorded).to eq(%w[fiber_b fiber_a])
    ensure
      ActiveSupport::IsolatedExecutionState.isolation_level = original_level
    end
  end

  describe "opt-in budget preflight" do
    before do
      allow(LlmCostTracker::Ingestion::Inbox).to receive(:save).and_return(true)
      allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_return(true)
    end

    it "raises before tracking when track opts in" do
      allow(LlmCostTracker::Budget).to receive(:enforce!).and_raise(
        LlmCostTracker::BudgetExceededError.new(budget_type: :monthly, total: 1.0, budget: 0.01)
      )

      expect do
        LlmCostTracker.track(
          provider: "openai",
          model: "gpt-4o",
          tokens: { input_tokens: 1, output_tokens: 1 },
          enforce_budget: true
        )
      end.to raise_error(LlmCostTracker::BudgetExceededError)
    end

    it "raises before running the track_stream block when over budget" do
      LlmCostTracker.configure do |config|
        config.monthly_budget = 0.01
        config.budget_exceeded_behavior = :block_requests
      end

      allow(LlmCostTracker::Budget).to receive(:enforce!).and_raise(
        LlmCostTracker::BudgetExceededError.new(budget_type: :monthly, total: 1.0, budget: 0.01)
      )

      ran = false
      expect do
        LlmCostTracker.track_stream(
          provider: "openai",
          model: "gpt-4o",
          enforce_budget: true
        ) do |_stream|
          ran = true
        end
      end.to raise_error(LlmCostTracker::BudgetExceededError)

      expect(ran).to be false
    end

    it "does not preflight by default" do
      expect(LlmCostTracker::Budget).not_to receive(:enforce!)

      LlmCostTracker.track(
        provider: "openai",
        model: "gpt-4o",
        tokens: { input_tokens: 1, output_tokens: 1 },
      )
    end

    it "does not treat enforce_budget as a tag" do
      recorded = []
      subscription = ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
        recorded << payload
      end

      allow(LlmCostTracker::Budget).to receive(:enforce!)

      LlmCostTracker.track(
        provider: "openai",
        model: "gpt-4o",
        tokens: { input_tokens: 1, output_tokens: 1 },
        enforce_budget: true
      )

      expect(recorded.first[:tags]).not_to have_key(:enforce_budget)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
  end
end
