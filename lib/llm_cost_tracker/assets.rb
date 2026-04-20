# frozen_string_literal: true

require "digest"

module LlmCostTracker
  module Assets
    ROOT = File.expand_path("../../app/assets/llm_cost_tracker", __dir__)
    STYLESHEET = "application.css"

    class << self
      def root
        ROOT
      end

      def stylesheet_fingerprint
        @stylesheet_fingerprint ||= Digest::SHA256.file(File.join(ROOT, STYLESHEET)).hexdigest[0, 12]
      end

      def stylesheet_filename
        "application-#{stylesheet_fingerprint}.css"
      end
    end
  end
end
