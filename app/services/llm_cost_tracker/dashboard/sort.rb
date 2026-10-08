# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    module Sort
      DIRECTIONS = %w[asc desc].freeze

      Choice = Data.define(:column, :direction)

      def self.resolve(column, direction, natural_directions:, fallback:)
        column = natural_directions.key?(column.to_s) ? column.to_s : fallback
        direction = direction.to_s
        direction = natural_directions.fetch(column) unless DIRECTIONS.include?(direction)
        Choice.new(column: column, direction: direction)
      end
    end
  end
end
