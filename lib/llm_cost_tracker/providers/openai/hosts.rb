# frozen_string_literal: true

module LlmCostTracker
  module Providers
    module Openai
      module Hosts
        API_HOSTS = %w[
          api.openai.com
          us.api.openai.com
          eu.api.openai.com
          au.api.openai.com
          ca.api.openai.com
          jp.api.openai.com
          in.api.openai.com
          sg.api.openai.com
          kr.api.openai.com
          gb.api.openai.com
          ae.api.openai.com
        ].freeze

        DATA_RESIDENCY_HOST_PATTERN = /\A[a-z]{2,3}\.api\.openai\.com\z/

        def self.data_residency?(host)
          host.to_s.downcase.match?(DATA_RESIDENCY_HOST_PATTERN)
        end
      end
    end
  end
end
