# frozen_string_literal: true

module LlmCostTracker
  class AssetsController < ActionController::Base
    def stylesheet
      response.set_header("Cache-Control", cache_control_header)
      send_file LlmCostTracker::Assets::STYLESHEET_PATH, type: "text/css", disposition: "inline"
    end

    private

    def cache_control_header
      if Rails.env.development?
        "no-store"
      else
        "public, max-age=31536000, immutable"
      end
    end
  end
end
