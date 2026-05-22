# frozen_string_literal: true

module LlmCostTracker
  module Timing
    def self.now_monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def self.elapsed_ms(started_at)
      ((now_monotonic - started_at) * 1000).round
    end
  end
end
