# frozen_string_literal: true

require "uri"

module LlmCostTracker
  module RequestUrl
    class << self
      def label(value)
        uri = URI.parse(value.to_s)
        uri.query = nil
        uri.fragment = nil
        uri.user = nil if uri.respond_to?(:user=)
        uri.password = nil if uri.respond_to?(:password=)
        uri.to_s
      rescue URI::InvalidURIError
        value.to_s.split("?", 2).first
      end
    end
  end
end
