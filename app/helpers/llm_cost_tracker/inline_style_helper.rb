# frozen_string_literal: true

module LlmCostTracker
  module InlineStyleHelper
    UNSAFE_CSS_CHARS = /[<>{}"]/

    def inline_style(declarations)
      registry = inline_style_registry
      token = "lct-i-#{registry.length}"
      registry << [token, declarations.to_s.gsub(UNSAFE_CSS_CHARS, "")]
      token
    end

    def inline_style_block
      registry = inline_style_registry
      return "".html_safe if registry.empty?

      rules = registry.map { |token, decl| %([data-lct-style="#{token}"]{#{decl}}) }.join("\n")
      content_tag(:style, rules.html_safe, nonce: dashboard_csp_nonce)
    end

    private

    def inline_style_registry
      @inline_style_registry ||= []
    end
  end
end
