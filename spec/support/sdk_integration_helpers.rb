# frozen_string_literal: true

module SdkIntegrationHelpers
  FIXTURE_ROOT = File.expand_path("../fixtures/sdk_responses", __dir__)

  def configure_sdk_integration(name)
    allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_return(true)
    allow(LlmCostTracker::Ingestion::Inbox).to receive(:save).and_return(true)
    allow(LlmCostTracker::Call).to receive(:already_recorded?).and_return(false)
    LlmCostTracker.configure do |config|
      config.pricing.unknown_behavior = :ignore
      config.instrument(name)
    end
  end

  def capture_sdk_events
    events = []
    subscription = ActiveSupport::Notifications.subscribe(LlmCostTracker::Tracker::EVENT_NAME) do |*, payload|
      events << payload.merge(payload.fetch(:token_usage, {}))
    end
    yield events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  def sdk_fixture(provider, name)
    File.read(File.join(FIXTURE_ROOT, provider.to_s, name))
  end

  def stub_sdk_json(method, url, provider:, fixture:, status: 200, headers: {})
    WebMock.stub_request(method, url).to_return(
      status: status,
      body: sdk_fixture(provider, fixture),
      headers: { "Content-Type" => "application/json" }.merge(headers)
    )
  end

  def stub_sdk_sse(method, url, body:)
    WebMock.stub_request(method, url).to_return(
      status: 200,
      body: body,
      headers: { "Content-Type" => "text/event-stream" }
    )
  end
end

RSpec.configure { |c| c.include SdkIntegrationHelpers }
