# frozen_string_literal: true

require "digest"

module LlmCostTracker
  module Assets
    ROOT = File.expand_path("../../app/assets/llm_cost_tracker", __dir__)
    STYLESHEET = "application.css"
    STYLESHEET_PATH = File.join(ROOT, STYLESHEET).freeze
    STYLESHEET_FINGERPRINT = Digest::SHA256.file(STYLESHEET_PATH).hexdigest[0, 12].freeze
    STYLESHEET_FILENAME = "application-#{STYLESHEET_FINGERPRINT}.css".freeze

    class << self
      def root = ROOT
      def stylesheet_fingerprint = STYLESHEET_FINGERPRINT
      def stylesheet_filename = STYLESHEET_FILENAME
    end
  end
end
