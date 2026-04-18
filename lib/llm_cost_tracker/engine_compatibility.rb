# frozen_string_literal: true

module LlmCostTracker
  module EngineCompatibility
    REQUIRED_RAILS_VERSION = Gem::Version.new("7.1.0")

    class << self
      def check_rails_version!(version)
        return if Gem::Version.new(version) >= REQUIRED_RAILS_VERSION

        raise LlmCostTracker::Error, "LlmCostTracker::Engine requires Rails 7.1+"
      end
    end
  end
end
