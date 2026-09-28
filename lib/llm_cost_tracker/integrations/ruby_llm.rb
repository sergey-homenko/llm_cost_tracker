# frozen_string_literal: true

require_relative "ruby_llm/v1"
require_relative "ruby_llm/v2"

module LlmCostTracker
  module Integrations
    module RubyLlm
      class << self
        def install = implementation.install

        def status = implementation.status

        def implementation
          version = V2.gem_version
          version && version >= Gem::Version.new("2.0.0") ? V2 : V1
        end
      end
    end
  end
end
