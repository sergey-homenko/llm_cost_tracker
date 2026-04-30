# frozen_string_literal: true

module LlmCostTracker
  class Doctor
    Check = Data.define(:status, :name, :message)
  end
end
