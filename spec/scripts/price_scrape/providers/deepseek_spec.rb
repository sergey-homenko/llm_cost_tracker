# frozen_string_literal: true

require "spec_helper"
require "price_scrape/providers/deepseek"

RSpec.describe LlmCostTracker::Pricing::Scrape::Providers::Deepseek do
  let(:html) { File.read("spec/fixtures/scrape/deepseek_pricing.html", encoding: "utf-8") }
  let(:models) { described_class.new.call(html: html).models }
  let(:windows) do
    [{ "weekdays" => [1, 2, 3, 4, 5], "hours_utc" => ["00:00-01:00", "04:00-06:00", "10:00-24:00"] },
     { "weekdays" => [6, 7], "hours_utc" => ["00:00-24:00"] }]
  end

  it "reads peak rates as the base and off-peak rates as off_peak_ rates, per model column" do
    expect(models.fetch("deepseek-flash")).to eq(
      "input" => 0.3, "cache_read_input" => 0.006, "output" => 1.2,
      "off_peak_input" => 0.15, "off_peak_cache_read_input" => 0.003, "off_peak_output" => 0.6,
      "_off_peak_windows" => windows
    )
    expect(models.fetch("deepseek-v4-pro")).to include(
      "input" => 1.32, "cache_read_input" => 0.044, "output" => 3.96,
      "off_peak_input" => 0.66, "off_peak_cache_read_input" => 0.022, "off_peak_output" => 1.98
    )
  end

  it "gives the legacy names a column's footnote lists that column's prices" do
    expect(models.keys).to contain_exactly("deepseek-flash", "deepseek-v4-pro", "deepseek-v4-flash",
                                           "deepseek-v4-flash-vision-exp")
    expect(models.values_at("deepseek-v4-flash", "deepseek-v4-flash-vision-exp")).to all(eq(models["deepseek-flash"]))
  end

  it "derives the off-peak windows from whatever peak hours the footnote states" do
    page = html.sub("01:00 - 04:00 and 06:00 - 10:00 UTC, Monday through Friday",
                    "00:30 - 08:00 UTC, Monday through Saturday")

    expect(described_class.new.call(html: page).models.fetch("deepseek-v4-pro")["_off_peak_windows"]).to eq(
      [{ "weekdays" => [1, 2, 3, 4, 5, 6], "hours_utc" => ["00:00-00:30", "08:00-24:00"] },
       { "weekdays" => [7], "hours_utc" => ["00:00-24:00"] }]
    )
  end

  it "raises when the table, a price, the peak hours or a model footnote no longer parse" do
    scrape = ->(page) { described_class.new.call(html: page) }

    expect { scrape.call(html.gsub("PRICING", "COSTS")) }.to raise_error(described_class::Error, /table not found/)
    expect { scrape.call(html.sub("$0.66", "0.66 USD")) }.to raise_error(described_class::Error, /"0.66 USD"/)
    expect { scrape.call(html.sub("<tr><td>PEAK</td><td>$1.2</td><td>$3.96</td></tr>", "")) }
      .to raise_error(described_class::Error, /prices not found/)
    expect { scrape.call(html.sub("All other hours are off-peak", "Other hours vary")) }
      .to raise_error(described_class::Error, /peak hours not understood/)
    expect { scrape.call(html.sub("Monday through Friday", "on weekdays")) }
      .to raise_error(described_class::Error, /peak hours not understood/)
    expect { scrape.call(html.sub("Peak hours are", "Busy hours are")) }
      .to raise_error(described_class::Error, /footnote not found/)
    expect { scrape.call(html.sub("The legacy names", "The names")) }
      .to raise_error(described_class::Error, /footnote \(1\) names no legacy models/)
  end

  it "raises on a price row it does not know, wherever it appears, and on a peak range that wraps midnight" do
    rows = lambda do |label, off_peak, peak|
      %(<tr><td rowspan="2">#{label}</td><td>OFF-PEAK</td>#{off_peak}</tr><tr><td>PEAK</td>#{peak}</tr>)
    end
    cache_write = rows.call("1M INPUT TOKENS<br>(CACHE WRITE)", "<td>$9.5</td><td>$9.6</td>", "<td>$19</td><td>$19.2</td>")
    long_context = rows.call("1M INPUT TOKENS (&gt;256K CONTEXT)", "<td>$0.3</td><td>$1.32</td>",
                             "<td>$0.6</td><td>$2.64</td>")
    concurrency = '<tr><td colspan="3">Concurrency Limit'
    miss = '<tr><td rowspan="2">1M INPUT TOKENS<br>(CACHE MISS)'
    scrape = ->(page) { described_class.new.call(html: page) }

    expect { scrape.call(html.sub(concurrency, cache_write + concurrency)) }
      .to raise_error(described_class::Error, /price row "1M INPUT TOKENS\(CACHE WRITE\)" not understood/)
    expect { scrape.call(html.sub(miss, cache_write + miss)) }
      .to raise_error(described_class::Error, /CACHE WRITE\)" not understood/)
    expect { scrape.call(html.sub(concurrency, long_context + concurrency)) }
      .to raise_error(described_class::Error, />256K CONTEXT\)" not understood/)
    expect { scrape.call(html.sub("01:00 - 04:00 and 06:00 - 10:00 UTC", "22:00 - 02:00 UTC")) }
      .to raise_error(described_class::Error, /peak hours "22:00 - 02:00" not understood/)
  end

  it "raises when a price row repeats or peak ranges overlap" do
    hit = '<tr><td rowspan="2">1M INPUT TOKENS<br>(CACHE HIT)</td><td>OFF-PEAK</td><td>$0.003</td><td>$0.022</td></tr>' \
          "<tr><td>PEAK</td><td>$0.006</td><td>$0.044</td></tr>"
    concurrency = '<tr><td colspan="3">Concurrency Limit'

    expect { described_class.new.call(html: html.sub(concurrency, hit + concurrency)) }
      .to raise_error(described_class::Error, /off_peak_cache_read_input prices listed twice/)
    expect { described_class.new.call(html: html.sub("06:00 - 10:00", "03:00 - 10:00")) }
      .to raise_error(described_class::Error, /overlap/)
  end
end
