# frozen_string_literal: true

module LlmCostTracker
  class Error < StandardError; end

  class BudgetExceededError < Error
    attr_reader :monthly_total, :budget, :last_event

    def initialize(monthly_total:, budget:, last_event: nil)
      @monthly_total = monthly_total
      @budget = budget
      @last_event = last_event

      super("LLM monthly budget exceeded: $#{format('%.6f', monthly_total)} / $#{format('%.6f', budget)}")
    end
  end

  class UnknownPricingError < Error
    attr_reader :model

    def initialize(model:)
      @model = model

      super("No pricing configured for LLM model: #{model.inspect}")
    end
  end

  class StorageError < Error
    attr_reader :original_error

    def initialize(original_error)
      @original_error = original_error

      super("Failed to store LLM cost event: #{original_error.class}: #{original_error.message}")
    end
  end
end
