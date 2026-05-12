# frozen_string_literal: true

module LlmCostTracker
  class ProviderInvoice < ActiveRecord::Base
    before_validation :normalize_currency

    private

    def normalize_currency
      self.currency = currency.to_s.upcase if currency.present?
    end
  end
end
