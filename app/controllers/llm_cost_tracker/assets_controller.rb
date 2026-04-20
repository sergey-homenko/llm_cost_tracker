# frozen_string_literal: true

module LlmCostTracker
  class AssetsController < ActionController::Base
    skip_forgery_protection if respond_to?(:skip_forgery_protection)

    def stylesheet
      path = File.join(LlmCostTracker::Assets.root, LlmCostTracker::Assets::STYLESHEET)
      response.set_header("Cache-Control", "public, max-age=31536000, immutable")
      send_file path, type: "text/css", disposition: "inline"
    end
  end
end
