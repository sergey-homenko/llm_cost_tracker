# frozen_string_literal: true

require_relative "../providers/litellm"

module LlmCostTracker
  module Pricing::Scrape
    class CrossCheck
      class Comparison
        attr_reader :findings, :counts

        def initialize(registry, catalogue, today)
          @ours = registry.fetch("models", {})
          @absent = registry.dig("metadata", "absent_since") || {}
          @charges = registry.fetch("service_charges", {})
          @conversion = Providers::Litellm.convert(catalogue)
          @today = today.iso8601
          @counts = Hash.new { |counts, provider| counts[provider] = Hash.new(0) }
          @findings = []
        end

        def call(models_dev)
          providers.each { |provider| compare(provider) }
          GATED.each { |provider| confirm(provider, models_dev) }
          @conversion.unknown.each { |name, models| models.each { |model| add(:unknown, model, name) } }
          @conversion.unrepresentable.each do |reason, models|
            models.each { |model| add(:unrepresentable, model, nil, reason) }
          end
          self
        end

        private

        def add(section, model, field = nil, detail = nil)
          @findings << Finding.new(section:, model:, field:, detail:)
        end

        def providers
          (@ours.keys + @conversion.models.keys).map { |key| key.split("/").first }.uniq
        end

        def compare(provider)
          ours = models_of(@ours, provider)
          theirs = models_of(@conversion.models, provider)
          litellm_only = theirs - ours
          (ours & theirs).each { |model| compare_model(provider, model) }
          @counts[provider].merge!(litellm_only: litellm_only.size, ours_only: (ours - theirs).size)
          return unless FULLY_SCRAPED.include?(provider)

          litellm_only.each { |model| add(:model, model) if gap?(provider, model) }
        end

        def confirm(provider, models_dev)
          listed = models_of(@ours, provider).reject { |key| @absent.key?(key) }
          gate = Providers::Litellm.gate(provider, @conversion, models_dev, official(provider, listed), @today)
          gate.held.each do |model, (ours, theirs)|
            key = "#{provider}/#{model}"
            next if listed.include?(key)

            add(:held, key, nil, "LiteLLM #{ours.join('/')}, models.dev #{theirs.join('/')}")
          end
          (gate.unconfirmed.map { |model| "#{provider}/#{model}" } - listed).each { |model| add(:unconfirmed, model) }
        end

        def official(provider, listed)
          listed.reject { |key| @ours[key]["_source"] }.to_h { |key| [key.delete_prefix("#{provider}/"), @ours[key]] }
        end

        def compare_model(provider, model)
          prices = @ours.fetch(model)
          @conversion.models.fetch(model).each do |field, value|
            next unless compared?(provider, field)

            compare_value(provider, model, field, our_value(provider, prices, field), value)
          end
          uplift = Providers::Litellm.uplift(@conversion.entries.fetch(model))
          return unless uplift && prices.keys.none? { |key| key.include?("data_residency") }

          add(:field, model, "data_residency_*", uplift)
        end

        def compare_value(provider, model, field, mine, theirs)
          return add(:field, model, field) if mine.nil?

          different = Providers::Litellm.differ?(mine, theirs)
          @counts[provider][different ? :differ : :equal] += 1
          add(:difference, model, field, [mine, theirs]) if different
        end

        def compared?(provider, field)
          field != Pricing::Registry::CONTEXT_THRESHOLD_KEY && !UNCOMPARED.fetch(provider, []).include?(field)
        end

        def our_value(provider, prices, field)
          return prices[field] if prices.key?(field)

          context, tier, dimension = TIERED_FIELD.match(field).values_at(:context, :tier, :dimension)
          return @charges.dig(provider, field) unless context || tier

          derived_tier_value(prices, context, tier, dimension) if tier && !%w[input output].include?(dimension)
        end

        def derived_tier_value(prices, context, tier, dimension)
          standard, input, tier_input = prices.values_at(
            "#{context}#{dimension}",
            "#{context}input",
            "#{context}#{tier}_input"
          )
          standard * tier_input / input if standard && tier_input && input.to_f.positive?
        end

        def gap?(provider, model)
          fields = @conversion.models.fetch(model)
          Providers::Litellm.current?(@conversion.entries.fetch(model), fields, @today) &&
            !dated_twin?(provider, model, fields)
        end

        def dated_twin?(provider, model, fields)
          return false unless model.match?(DATED_SUFFIX)

          base = model.sub(DATED_SUFFIX, "")
          return true if @conversion.models[base] == fields

          ours = @ours[base]
          return false unless ours

          fields.none? do |field, value|
            compared?(provider, field) && ours.key?(field) && Providers::Litellm.differ?(ours[field], value)
          end
        end

        def models_of(table, provider)
          table.keys.select { |key| key.start_with?("#{provider}/") }
        end
      end
    end
  end
end
