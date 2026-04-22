# frozen_string_literal: true

module LlmCostTracker
  module PriceSync
    class ModelCatalog
      OPENROUTER_PROVIDER_PREFIXES = {
        openai: %w[openai],
        anthropic: %w[anthropic],
        gemini: %w[google]
      }.freeze
      LITELLM_PROVIDER_PREFIXES = {
        openai: [nil, "openai"],
        anthropic: [nil, "anthropic"],
        gemini: [nil, "gemini"]
      }.freeze
      ALIASES = {
        "gpt-4o-2024-05-13" => "gpt-4o"
      }.freeze

      class << self
        def resolve_from_litellm(our_model, payload)
          litellm_candidates(our_model).find { |candidate| payload.key?(candidate) }
        end

        def resolve_from_openrouter(our_model, index)
          openrouter_candidates(our_model).find { |candidate| index.key?(candidate) }
        end

        def guess_provider(our_model)
          case our_model.to_s
          when /\A(?:gpt-|o1|o3|o4|chatgpt|text-embedding)/
            :openai
          when /\Aclaude-/
            :anthropic
          when /\Agemini-/
            :gemini
          end
        end

        private

        def litellm_candidates(our_model)
          provider = guess_provider(our_model)
          prefixes = LITELLM_PROVIDER_PREFIXES.fetch(provider, [nil])

          model_variants(our_model).flat_map do |variant|
            prefixes.map { |prefix| prefix ? "#{prefix}/#{variant}" : variant }
          end.uniq
        end

        def openrouter_candidates(our_model)
          provider = guess_provider(our_model)
          prefixes = OPENROUTER_PROVIDER_PREFIXES.fetch(provider, [])

          model_variants(our_model).flat_map do |variant|
            prefixes.map { |prefix| "#{prefix}/#{variant}" }
          end.uniq
        end

        def model_variants(our_model)
          model = our_model.to_s
          canonical = ALIASES.fetch(model, model)

          [model, canonical].flat_map do |variant|
            [variant, anthropic_version_variant(variant)]
          end.compact.uniq
        end

        def anthropic_version_variant(model)
          return nil unless guess_provider(model) == :anthropic

          model.gsub(/(?<=\d)-(?=\d)/, ".")
        end
      end
    end
  end
end
