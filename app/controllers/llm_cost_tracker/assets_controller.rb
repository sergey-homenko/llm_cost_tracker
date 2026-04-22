# frozen_string_literal: true

module LlmCostTracker
  class AssetsController < ActionController::Base
    def stylesheet
      response.set_header("Cache-Control", "public, max-age=31536000, immutable")
      send_file LlmCostTracker::Assets::STYLESHEET_PATH, type: "text/css", disposition: "inline"
    end
  end
end
