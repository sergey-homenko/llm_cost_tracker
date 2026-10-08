# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    class SpendChart
      WIDTH = 1180
      PADDING = { top: 16, right: 16, bottom: 28, left: 56 }.freeze
      MIN_MAX_COST = 0.0001

      attr_reader :points, :height, :y_ticks, :max_cost, :coords, :comparison_coords

      def initialize(points, comparison_points: nil, height: 180, y_ticks: 3)
        @points = points
        @height = height
        @y_ticks = y_ticks
        costs = points.map { |point| point[:cost].to_f } + Array(comparison_points).map { |point| point[:cost].to_f }
        @max_cost = [costs.max.to_f, MIN_MAX_COST].max
        @coords = coords_for(points)
        @comparison_coords = coords_for(comparison_points) if comparison_points.present?
      end

      def peak_index
        @peak_index ||= points.each_with_index.max_by { |point, _| point[:cost].to_f }&.last
      end

      def left
        PADDING[:left]
      end

      def right
        left + plot_width
      end

      def baseline
        PADDING[:top] + plot_height
      end

      def tick_y(index)
        PADDING[:top] + (plot_height * index.to_f / y_ticks)
      end

      def tick_value(index)
        max_cost * (y_ticks - index).to_f / y_ticks
      end

      def label_indexes
        count = points.size
        count <= 2 ? (0...count).to_a : [0, count / 2, count - 1].uniq
      end

      private

      def plot_width
        WIDTH - PADDING[:left] - PADDING[:right]
      end

      def plot_height
        height - PADDING[:top] - PADDING[:bottom]
      end

      def coords_for(series)
        step = series.size > 1 ? plot_width.to_f / (series.size - 1) : 0.0
        series.each_with_index.map do |point, index|
          [left + (index * step), baseline - ((point[:cost].to_f / max_cost) * plot_height)]
        end
      end
    end
  end
end
