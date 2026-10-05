# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Pricing::OffPeak do
  let(:windows) do
    described_class.windows(
      [{ "weekdays" => [1, 2, 3, 4, 5], "hours_utc" => ["00:00-01:00", "04:00-06:00", "10:00-24:00"] },
       { "weekdays" => [6, 7], "hours_utc" => ["00:00-24:00"] }],
      label: "windows"
    )
  end

  def off_peak?(*utc) = described_class.cover?(windows, Time.utc(*utc))

  it "covers a call from a window's start up to, but not including, its end" do
    expect([[0, 59, 59], [1, 0, 0], [3, 59, 59], [4, 0, 0], [9, 59, 59], [10, 0, 0], [23, 59, 59]]
             .map { |time| off_peak?(2026, 9, 28, *time) }).to eq([true, false, false, true, false, true, true])
  end

  it "matches ISO weekdays in UTC whatever the call's own offset" do
    expect(off_peak?(2026, 10, 3, 2)).to be(true)
    expect(off_peak?(2026, 10, 4, 8)).to be(true)
    expect(off_peak?(2026, 10, 2, 7)).to be(false)
    expect(described_class.cover?(windows, Time.new(2026, 9, 28, 3, 30, 0, "+03:00"))).to be(true)
  end

  it "returns the windows with string keys and rejects any other shape" do
    expect(described_class.windows([{ weekdays: [7], hours_utc: ["12:00-13:30"] }], label: "x"))
      .to eq([{ "weekdays" => [7], "hours_utc" => ["12:00-13:30"] }])

    malformed = [
      nil, [], { "weekdays" => [1], "hours_utc" => ["00:00-01:00"] }, ["00:00-01:00"],
      [{ "weekdays" => [1] }], [{ "weekdays" => [1], "hours_utc" => ["00:00-01:00"], "tz" => "UTC" }],
      [{ "weekdays" => [0], "hours_utc" => ["00:00-01:00"] }], [{ "weekdays" => ["1"], "hours_utc" => ["00:00-01:00"] }],
      [{ "weekdays" => [1], "hours_utc" => "00:00-01:00" }], [{ "weekdays" => [1], "hours_utc" => ["10:00-00:00"] }],
      [{ "weekdays" => [1], "hours_utc" => ["01:00-01:00"] }], [{ "weekdays" => [1], "hours_utc" => ["24:00-24:00"] }],
      [{ "weekdays" => [1], "hours_utc" => ["1:00-2:00"] }]
    ]
    malformed.each do |value|
      expect { described_class.windows(value, label: "_off_peak_windows") }
        .to raise_error(ArgumentError, /_off_peak_windows must be a list of windows/), value.inspect
    end
  end
end
