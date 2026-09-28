# frozen_string_literal: true

require_relative "ruby_llm/v1"

module LlmCostTracker
  module Integrations
    module RubyLlm
      class << self
        def install = implementation.install

        def status = implementation.status

        def implementation = V1
      end
    end
  end
end
