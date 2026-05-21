# frozen_string_literal: true

module SdkFixtureDeepToH
  def self.normalize(value)
    case value
    when Hash then value.transform_values { |v| normalize(v) }
    when Array then value.map { |v| normalize(v) }
    else value.respond_to?(:deep_to_h) ? value.deep_to_h : value
    end
  end

  def deep_to_h
    to_h.transform_values { |v| SdkFixtureDeepToH.normalize(v) }
  end
end

module SdkIntegrationHelpers
  FIXTURE_ROOT = File.expand_path("../fixtures/sdk_responses", __dir__)

  def configure_sdk_integration(name)
    allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_return(true)
    allow(LlmCostTracker::Ingestion::Inbox).to receive(:save).and_return(true)
    LlmCostTracker.configure do |config|
      config.unknown_pricing_behavior = :ignore
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
