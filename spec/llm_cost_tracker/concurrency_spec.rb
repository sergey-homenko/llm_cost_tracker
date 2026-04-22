# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/stream_collector"

RSpec.describe "concurrency", :aggregate_failures do
  describe LlmCostTracker::StreamCollector do
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
        rescue FrozenError => error
          write_errors << error
        end
      end

      finisher = Thread.new { collector.finish! }

      (writers + [finisher]).each(&:join)

      expect(recorded.size).to eq(1)
      expect(recorded.first[:input_tokens]).to eq(7)
      expect(recorded.first[:output_tokens]).to eq(3)
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
  end

  describe LlmCostTracker::Parsers::Registry do
    it "stays consistent when register! and lookups run concurrently" do
      parser_class = Class.new(LlmCostTracker::Parsers::Base) do
        def provider_names
          %w[concurrent_parser]
        end

        def match?(_url)
          false
        end

        def parse(*)
          nil
        end
      end

      lookup_threads = Array.new(8) do
        Thread.new do
          200.times { described_class.find_for_provider("openai_compatible") }
        end
      end

      register_threads = Array.new(8) do
        Thread.new do
          10.times { described_class.register(parser_class.new) }
        end
      end

      (lookup_threads + register_threads).each(&:join)

      expect(described_class.find_for_provider("openai_compatible")).to be_a(LlmCostTracker::Parsers::OpenaiCompatible)
      expect(described_class.find_for_provider("concurrent_parser")).to be_a(parser_class)
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

    it "allows a later configure block to replace frozen shared state" do
      LlmCostTracker.configure { |config| config.default_tags = { env: "test" } }

      expect do
        LlmCostTracker.configure { |config| config.default_tags = { env: "prod" } }
      end.not_to raise_error

      expect(LlmCostTracker.configuration.default_tags).to eq(env: "prod")
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

  describe "opt-in budget preflight" do
    it "raises before tracking when track opts in" do
      allow(LlmCostTracker::Tracker).to receive(:enforce_budget!).and_raise(
        LlmCostTracker::BudgetExceededError.new(monthly_total: 1.0, budget: 0.01)
      )

      expect do
        LlmCostTracker.track(
          provider: "openai",
          model: "gpt-4o",
          input_tokens: 1,
          output_tokens: 1,
          enforce_budget: true
        )
      end.to raise_error(LlmCostTracker::BudgetExceededError)
    end

    it "raises before running the track_stream block when over budget" do
      LlmCostTracker.configure do |config|
        config.storage_backend = :custom
        config.custom_storage = ->(_event) {}
        config.monthly_budget = 0.01
        config.budget_exceeded_behavior = :block_requests
      end

      allow(LlmCostTracker::Tracker).to receive(:enforce_budget!).and_raise(
        LlmCostTracker::BudgetExceededError.new(monthly_total: 1.0, budget: 0.01)
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
      expect(LlmCostTracker::Tracker).not_to receive(:enforce_budget!)

      LlmCostTracker.track(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 1,
        output_tokens: 1
      )
    end

    it "does not treat enforce_budget as a tag" do
      recorded = []
      subscription = ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
        recorded << payload
      end

      allow(LlmCostTracker::Tracker).to receive(:enforce_budget!)

      LlmCostTracker.track(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 1,
        output_tokens: 1,
        enforce_budget: true
      )

      expect(recorded.first[:tags]).not_to have_key(:enforce_budget)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
  end
end
