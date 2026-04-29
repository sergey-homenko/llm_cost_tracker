# frozen_string_literal: true

require "uri"

module LlmCostTracker
  module RequestUrl
    class << self
      def label(value)
        uri = URI.parse(value.to_s)
        uri.query = nil
        uri.fragment = nil
        uri.try(:user=, nil)
        uri.try(:password=, nil)
        uri.to_s
      rescue URI::InvalidURIError
        value.to_s.split("?", 2).first
      end
    end
  end
end
