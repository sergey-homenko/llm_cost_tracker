# frozen_string_literal: true

module LlmCostTracker
  module Timing
    module_function

    def now_monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started_at)
      ((now_monotonic - started_at) * 1000).round
    end
  end
end
