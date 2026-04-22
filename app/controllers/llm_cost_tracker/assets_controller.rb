# frozen_string_literal: true

module LlmCostTracker
  class AssetsController < ActionController::Base
    skip_forgery_protection if respond_to?(:skip_forgery_protection)

    def stylesheet
      response.set_header("Cache-Control", "public, max-age=31536000, immutable")
      send_file LlmCostTracker::Assets::STYLESHEET_PATH, type: "text/css", disposition: "inline"
    end
  end
end
