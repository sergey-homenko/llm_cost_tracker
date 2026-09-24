# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "../../dummy/config/environment"

RSpec.describe "LlmCostTracker::Engine query reflection" do
  include_context "with mounted llm cost tracker engine"

  pages = %w[/llm-costs /llm-costs/calls /llm-costs/models /llm-costs/tags /llm-costs/tags/feature
             /llm-costs/tags/feature?tag_value=chat /llm-costs/data_quality]

  def with_query(page, query)
    "#{page}#{page.include?('?') ? '&' : '?'}#{query}"
  end

  def hrefs(body)
    body.scan(/(?:href|action)="([^"]*)"/).flatten
  end

  before do
    create_call(provider: "openai", model: "gpt-4o", tags: { feature: "chat" })
    create_call(provider: "anthropic", model: "claude-haiku-4-5", tags: { feature: "search" })
  end

  {
    "script_name=%2F%2Fevil.example" => /evil\.example/,
    "original_script_name=%2F%2Fevil.example" => /evil\.example/,
    "anchor=injected" => /#injected/,
    "params%5Binjected%5D=1" => /injected/,
    "trailing_slash=1" => %r{/llm-costs/[a-z_]+(/[^/?]+)?/(\?|\z)},
    "key=injected" => /injected/
  }.each do |query, marker|
    it "does not let #{query.split('=').first} rewrite dashboard links" do
      pages.each do |page|
        response = get(with_query(page, query))

        expect(response.status).to eq(200), "#{page}: #{response.status}"
        expect(hrefs(response.body).grep(marker)).to be_empty, page
      end
    end
  end

  it "does not let format rewrite dashboard links" do
    ["/llm-costs/calls", "/llm-costs/tags", "/llm-costs/tags/feature"].each do |page|
      response = get(with_query(page, "format=json"))

      expect(response.status).to eq(200)
      expect(hrefs(response.body).grep(/\.json/)).to be_empty, page
    end
  end

  %w[original_script_name%5B%5D=x _recall=x path_params=x key%5B%5D=a&key%5B%5D=b].each do |query|
    it "ignores #{query.split('=').first} instead of failing" do
      pages.each do |page|
        expect(get(with_query(page, query)).status).to eq(200), page
      end
    end
  end

  it "does not repeat unknown query parameters in dashboard links or forms" do
    pages.each do |page|
      response = get(with_query(page, "zzz=reflectedjunk"))

      expect(response.status).to eq(200)
      expect(response.body).not_to include("reflectedjunk"), page
    end
  end

  it "keeps every dashboard filter, sort, and page setting in its links" do
    query = {
      from: (Date.current - 7).iso8601, to: Date.current.iso8601, provider: "openai", model: "gpt-4o",
      tag: { feature: "chat" }, stream: "no", usage_source: "response", cost_status: "incomplete",
      sort: "cost", dir: "asc", page: "2", per: "25"
    }
    expect(query.keys + [:tag_value]).to match_array(LlmCostTracker::Dashboard::Params::QUERY_KEYS)

    export = hrefs(get("/llm-costs/calls?#{query.to_query}").body).find { |href| href.include?("calls.csv") }

    query.each { |key, value| expect(export).to include({ key => value }.to_query) }
  end

  it "keeps the tag value and date range in the tag value page's links" do
    dates = { from: (Date.current - 7).iso8601, to: Date.current.iso8601 }
    response = get("/llm-costs/tags/feature?#{dates.merge(tag_value: 'chat', provider: 'openai').to_query}")

    clear = hrefs(response.body).find { |href| href.start_with?("/llm-costs/tags/feature?") && !href.include?("provider") }
    expect(clear).to include("tag_value=chat", dates.slice(:from).to_query, dates.slice(:to).to_query)
  end

  it "accepts a query string up to the size limit and rejects a longer one without repeating it" do
    limit = LlmCostTracker::ApplicationController::MAX_QUERY_BYTES
    at_limit = get("/llm-costs/tags/feature?stream=#{'x' * (limit - 'stream='.bytesize)}")
    over_limit = get("/llm-costs/tags/feature?stream=#{'x' * (limit - 'stream='.bytesize + 1)}")

    expect(at_limit.status).to eq(200)
    expect(over_limit.status).to eq(400)
    expect(over_limit.body).to include("query string exceeds 16 KB")
    expect(over_limit.body).not_to include("x" * 100)
  end
end
