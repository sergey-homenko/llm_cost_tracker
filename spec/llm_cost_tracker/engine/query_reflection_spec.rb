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

  it "keeps link options and unknown parameters in the query out of dashboard links and forms" do
    rewrites = %w[script_name=%2F%2Fevil.example original_script_name=%2F%2Fevil.example anchor=injected
                  params%5Binjected%5D=1 trailing_slash=1 key=injected _recall=x path_params=x zzz=reflectedjunk]
    malformed = %w[original_script_name%5B%5D=x key%5B%5D=a key%5B%5D=b]

    pages.product([rewrites, malformed]).each do |page, query|
      response = get(with_query(page, query.join("&")))

      expect(response.status).to eq(200), page
      expect(hrefs(response.body).grep(%r{evil\.example|injected|/llm-costs/[a-z_]+(/[^/?]+)?/(\?|\z)})).to be_empty, page
      expect(response.body).not_to include("reflectedjunk"), page
    end
  end

  it "does not let format rewrite dashboard links" do
    %w[/llm-costs/calls /llm-costs/tags /llm-costs/tags/feature].each do |page|
      response = get("#{page}?format=json")

      expect(response.status).to eq(200)
      expect(hrefs(response.body).grep(/\.json/)).to be_empty, page
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
