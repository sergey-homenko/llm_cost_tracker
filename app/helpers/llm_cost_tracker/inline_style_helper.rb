# frozen_string_literal: true

module LlmCostTracker
  module InlineStyleHelper
    UNSAFE_CSS_CHARS = /[<>{}]/

    def inline_style(declarations)
      registry = inline_style_registry
      element_id = "lct-i-#{registry.length}"
      registry << [element_id, declarations.to_s.gsub(UNSAFE_CSS_CHARS, "")]
      element_id
    end

    def inline_style_block
      registry = inline_style_registry
      return "".html_safe if registry.empty?

      rules = registry.map { |id, decl| "##{id}{#{decl}}" }.join("\n")
      content_tag(:style, rules.html_safe, nonce: dashboard_csp_nonce)
    end

    private

    def inline_style_registry
      @inline_style_registry ||= []
    end
  end
end
