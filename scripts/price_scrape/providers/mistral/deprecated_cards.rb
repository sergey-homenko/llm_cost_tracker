# frozen_string_literal: true

require "date"
require "json"

require_relative "../litellm"

module LlmCostTracker
  module Pricing::Scrape
    module Providers
      class Mistral < Litellm
        class DeprecatedCards
          PUSH = %r{self\.__next_f\.push\((.*?)\)</script>}m
          LIST = '{"models":[{'

          def self.call(page, today) = new(page).call(today)

          def initialize(page)
            @page = page
          end

          def call(today)
            cards = models.filter_map do |model|
              retires = model["retiredAt"] or next
              [model.fetch("href").delete_prefix("/models/"), model.fetch("modelIds"), Date.parse(retires)]
            end
            cards.partition { |_card, _ids, retires| retires >= today }
          end

          private

          def models
            element = list
            props = element[3] if element.is_a?(Array)
            models = props["models"] if props.is_a?(Hash)
            return models if models.is_a?(Array) && models.all? { |model| model.is_a?(Hash) && model.key?("modelIds") }

            raise Error, "Mistral retired models list not found or changed"
          end

          def list
            stream = @page.scan(PUSH).filter_map { |(chunk)| JSON.parse(chunk).then { |kind, text| text if kind == 1 } }
            line = stream.join.each_line.find { |candidate| candidate.include?(LIST) } or return
            JSON.parse(line.split(":", 2).last)
          end
        end
      end
    end
  end
end
