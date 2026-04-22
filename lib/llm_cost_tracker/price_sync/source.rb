# frozen_string_literal: true

module LlmCostTracker
  module PriceSync
    class Source
      def fetch(current_models:, fetcher:)
        raise NotImplementedError
      end

      def name
        self.class.name.split("::").last.downcase.to_sym
      end

      def priority
        100
      end

      def url
        raise NotImplementedError
      end

      private

      def response_version(response)
        response.source_version
      end
    end
  end
end
