# frozen_string_literal: true

module LlmCostTracker
  class Error < StandardError; end

  class InvalidFilterError < Error; end

  class BudgetExceededError < Error
    attr_reader :total, :budget, :budget_type, :last_event

    def initialize(budget:, budget_type:, total:, last_event: nil)
      @total = total
      @budget = budget
      @budget_type = budget_type
      @last_event = last_event

      super(
        "LLM #{@budget_type.to_s.tr('_', '-')} budget exceeded: " \
        "$#{format('%.6f', @total)} / $#{format('%.6f', budget)}"
      )
    end
  end

  class UnknownPricingError < Error
    attr_reader :model

    def initialize(model:)
      @model = model

      super("No pricing configured for LLM model: #{model.inspect}")
    end
  end
end
