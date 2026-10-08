# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../dummy/config/environment"

RSpec.describe LlmCostTracker::ApplicationHelper do
  subject(:helper_object) do
    Class.new do
      include LlmCostTracker::ApplicationHelper
    end.new
  end

  it "includes the sortable table helper for hosts that set include_all_helpers = false" do
    expect(described_class.ancestors).to include(LlmCostTracker::SortableTableHelper)
  end

  it "calculates display percentages with a zero denominator guard" do
    expect(helper_object.coverage_percent(2, 4)).to eq(50.0)
    expect(helper_object.coverage_percent(2, 0)).to eq(0.0)
  end

  it "renders USD with a $ symbol and other currencies with an ISO-code suffix" do
    expect(helper_object.money(1.23)).to eq("$1.23")
    expect(helper_object.money(1.23, currency: "USD")).to eq("$1.23")
    expect(helper_object.money(1.23, currency: "EUR")).to eq("1.23 EUR")
    expect(helper_object.money(1.23, currency: nil)).to eq("$1.23")
  end

  it "threads currency through optional_money and renders n/a for nil" do
    expect(helper_object.optional_money(nil, currency: "EUR")).to eq("n/a")
    expect(helper_object.optional_money(2.5, currency: "EUR")).to eq("2.50 EUR")
  end

  it "truncates long tag chip values at the display boundary" do
    entry = helper_object.tag_chip_entries({ feature: "x" * 100 }).first

    expect(entry).to eq(key: "feature", value: "#{'x' * 80}...")
  end

  it "parses JSON-encoded metadata strings so masking redacts provider IDs before rendering" do
    raw = { "provider_api_key_id" => "sk-live-secret-abc", "feature" => "ok" }.to_json
    masked = LlmCostTracker::Dashboard::Masking.mask_hash(helper_object.masked_metadata_hash(raw))

    expect(masked["provider_api_key_id"]).to eq("***-abc")
    expect(masked["provider_api_key_id"]).not_to include("sk-live-secret")
    expect(masked["feature"]).to eq("ok")
  end

  it "returns {} for non-JSON strings" do
    expect(helper_object.masked_metadata_hash("not json at all")).to eq({})
  end

  it "passes Hash inputs through unchanged" do
    hash = { "provider_api_key_id" => "sk-live-x" }

    expect(helper_object.masked_metadata_hash(hash)).to equal(hash)
  end

  it "returns {} for nil" do
    expect(helper_object.masked_metadata_hash(nil)).to eq({})
  end

  it "labels spend deltas against the prior period" do
    neutral = "lct-delta-badge lct-delta-neutral"

    expect(helper_object.delta_badge(nil)).to eq(text: "n/a vs. prior", css_class: neutral)
    expect(helper_object.delta_badge(-0.04)).to eq(text: "0.0% vs. prior", css_class: neutral)
    expect(helper_object.delta_badge(12.34)).to eq(text: "+12.3% vs. prior", css_class: "lct-delta-badge lct-delta-up")
    expect(helper_object.delta_badge(BigDecimal("-3.21")))
      .to eq(text: "-3.2% vs. prior", css_class: "lct-delta-badge lct-delta-down")
    expect(helper_object.delta_badge(7, mode: :neutral)).to eq(text: "+7.0% vs. prior", css_class: neutral)
  end

  it "builds dashboard filter paths without blank values while keeping list values" do
    request = Struct.new(:path, :query_parameters).new("/llm-costs/calls", {})
    helper_object.define_singleton_method(:request) { request }

    expect(helper_object.dashboard_filter_path(sort: " ", dir: nil)).to eq("/llm-costs/calls")
    expect(helper_object.dashboard_filter_path(per: ["5", " "], tag: { feature: " chat ", team: "" }))
      .to eq("/llm-costs/calls?per%5B%5D=5&tag%5Bfeature%5D=chat")
  end

  it "draws a single-day spend chart as a flat area under one point" do
    svg = helper_object.spend_chart_svg([{ label: "2026-04-20", cost: 2.0 }])

    expect(svg).to include(%(<path class="lct-chart-area" d="M56.00,152.00 L56.00,16.00 L1164.00,152.00 Z"/>))
    expect(svg).to include(%(<circle class="lct-chart-peak" cx="56.00" cy="16.00" r="4"/><title>2026-04-20: $2.00))
    expect(svg).to include(%(<text class="lct-chart-axis" x="56.00" y="172.00" text-anchor="start">2026-04-20</text>))
  end

  it "scales a two-day spend chart and its comparison series to a shared maximum" do
    svg = helper_object.spend_chart_svg(
      [{ label: "a", cost: 1.0 }, { label: "b", cost: 3.0 }],
      comparison_points: [{ label: "p1", cost: 0.0 }, { label: "p2", cost: 6.0 }]
    )

    expect(svg).to include(%(d="M56.00,129.33 L1164.00,84.00 L1164.00,152.00 L56.00,152.00 Z"))
    expect(svg).to include(%(<path class="lct-chart-line-secondary" d="M56.00,152.00 L1164.00,16.00"/>))
    expect(svg).to include(%(text-anchor="end">b</text>))
    expect(svg).to include(%(text-anchor="end">$6.00</text>))
  end
end
