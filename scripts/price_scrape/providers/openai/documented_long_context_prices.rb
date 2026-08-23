# frozen_string_literal: true

require "cgi"

require_relative "../../../../lib/llm_cost_tracker/pricing/registry"
require_relative "../base"
require_relative "model_ids"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Openai < Base
        module DocumentedLongContextPrices
          MODEL_DOC_URL_PREFIX = "https://developers.openai.com/api/docs/models/"
          CONTEXT_QUALIFIER = /\(<\d+K context length\)/
          PREMIUM_SENTENCE = /
            prompts\swith\s>([\d,]+)K\sinput\stokens\sare\spriced\sat\s
            ([\d.]+)x\sinput\sand\s([\d.]+)x\soutput([^.]*)\.
          /xi
          TIER_PREFIXES = { "standard" => "", "batch" => "batch_", "flex" => "flex_", "fast" => "fast_" }.freeze
          PREMIUM_BY_FIELD = {
            "input" => :input, "cache_read_input" => :input,
            "cache_write_input" => :input, "output" => :output
          }.freeze

          class << self
            def model_ids
              MODEL_ID_BY_DISPLAY_NAME.select { |name, _| name.match?(CONTEXT_QUALIFIER) }.values.uniq
            end

            def source_urls
              model_ids.map { |model_id| doc_url(model_id) }
            end

            def call(models, pages)
              model_ids.each_with_object({}) do |model_id, priced|
                fields = models[model_id]
                next unless fields
                next if fields.key?(Pricing::Registry::CONTEXT_THRESHOLD_KEY)

                premium = premium_for(model_id, pages[doc_url(model_id)])
                priced[model_id] = long_context_prices(fields, premium) if premium
              end
            end

            private

            def doc_url(model_id)
              "#{MODEL_DOC_URL_PREFIX}#{model_id}"
            end

            def premium_for(model_id, page)
              match = plain_text(page).match(PREMIUM_SENTENCE)
              unless match
                warn "[openai] no documented long-context premium for #{model_id}, see #{doc_url(model_id)}"
                return nil
              end

              {
                threshold: Integer(match[1].delete(",")) * 1_000,
                input: Float(match[2]),
                output: Float(match[3]),
                tiers: tiers(match[4])
              }
            end

            def plain_text(page)
              CGI.unescapeHTML(page.to_s).gsub(/<[^>]+>/, " ").gsub(/\s+/, " ")
            end

            def tiers(text)
              named = TIER_PREFIXES.keys.select { |tier| text.match?(/\b#{tier}\b/i) }
              named.empty? ? TIER_PREFIXES.keys : named
            end

            def long_context_prices(fields, premium)
              threshold = { Pricing::Registry::CONTEXT_THRESHOLD_KEY => premium.fetch(:threshold) }
              premium.fetch(:tiers).each_with_object(threshold) do |tier, prices|
                prefix = TIER_PREFIXES.fetch(tier)
                PREMIUM_BY_FIELD.each do |field, kind|
                  base = fields["#{prefix}#{field}"]
                  prices["above_context_#{prefix}#{field}"] = (base * premium.fetch(kind)).round(6) if base
                end
              end
            end
          end
        end
      end
    end
  end
end
