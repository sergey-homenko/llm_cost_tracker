# frozen_string_literal: true

module LlmCostTracker
  class Error < StandardError; end

  class InvalidFilterError < Error; end

  class BudgetExceededError < Error
    attr_reader :monthly_total, :daily_total, :call_cost, :total, :budget, :budget_type, :last_event

    def initialize(budget:, last_event: nil, budget_type: nil, total: nil, monthly_total: nil, daily_total: nil,
                   call_cost: nil)
      @monthly_total = monthly_total
      @daily_total = daily_total
      @call_cost = call_cost
      @total = total || monthly_total || daily_total || call_cost
      @budget = budget
      @budget_type = budget_type || inferred_budget_type
      @last_event = last_event

      super("LLM #{budget_label} budget exceeded: $#{format('%.6f', @total)} / $#{format('%.6f', budget)}")
    end

    private

    def inferred_budget_type
      return :monthly if monthly_total
      return :daily if daily_total
      return :per_call if call_cost

      :unknown
    end

    def budget_label
      budget_type.to_s.tr("_", "-")
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
