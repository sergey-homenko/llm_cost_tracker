# frozen_string_literal: true

module LlmCostTracker
  class Configuration
    attr_accessor :enabled,
                  :storage_backend,    # :log, :active_record, :custom
                  :custom_storage,     # callable object for :custom backend
                  :default_tags,       # Hash of default tags added to every event
                  :on_budget_exceeded, # callable, receives event hash
                  :monthly_budget,     # Float, in USD — nil means no limit
                  :log_level,          # :debug, :info, :warn
                  :pricing_overrides   # Hash to override built-in pricing

    def initialize
      @enabled            = true
      @storage_backend    = :log
      @custom_storage     = nil
      @default_tags       = {}
      @on_budget_exceeded = nil
      @monthly_budget     = nil
      @log_level          = :info
      @pricing_overrides  = {}
    end

    def active_record?
      storage_backend == :active_record
    end

    def log?
      storage_backend == :log
    end
  end
end
