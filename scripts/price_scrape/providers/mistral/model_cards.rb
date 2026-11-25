# frozen_string_literal: true

require_relative "../litellm"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Mistral < Litellm
        class ModelCards
          IDS = /\\"modelIds\\":\[([^\]]*)\]/
          ALIASES = /\\"aliases\\":\[([^\]]*)\]/

          attr_reader :api_names, :renamed

          def initialize(pages, listed)
            names = pages.transform_values { |page| list(page, IDS) }
            unnamed = names.find { |card, ids| ids.nil? && listed.key?(card) }&.first
            raise Error, "Mistral model card #{MODELS_SOURCE_URL}/#{unnamed} lists no API names" if unnamed

            @api_names = names.compact
            @renamed = pages.flat_map { |card, page| list(page, ALIASES).to_a.product([card]) }.to_h
          end

          private

          def list(page, pattern)
            ids = page.to_s[pattern, 1] or return
            ids.scan(/\\"([^\\"]+)\\"/).flatten
          end
        end
      end
    end
  end
end
