# frozen_string_literal: true

module LlmCostTracker
  module ChartHelper
    CHART_OPEN_TAG = "<svg class=\"lct-chart\" viewBox=\"0 0 %<width>s %<height>s\" " \
                     "preserveAspectRatio=\"xMidYMid meet\" role=\"img\" aria-label=\"Daily spend trend\">"
    CHART_GRADIENT = "<defs><linearGradient id=\"lct-chart-grad\" x1=\"0\" x2=\"0\" y1=\"0\" y2=\"1\">" \
                     "<stop offset=\"0%\" stop-color=\"var(--lct-accent)\" stop-opacity=\"0.28\"/>" \
                     "<stop offset=\"100%\" stop-color=\"var(--lct-accent)\" stop-opacity=\"0.02\"/>" \
                     "</linearGradient></defs>"

    def spend_chart_svg(points, comparison_points: nil, height: 180, y_ticks: 3)
      return nil if points.blank?

      chart = Dashboard::SpendChart.new(points, comparison_points: comparison_points, height: height, y_ticks: y_ticks)
      [
        format(CHART_OPEN_TAG, width: Dashboard::SpendChart::WIDTH, height: chart.height),
        "<title>Daily spend trend</title>",
        CHART_GRADIENT,
        *(0..chart.y_ticks).map { |index| chart_tick(chart, index) },
        chart_paths(chart),
        *chart.coords.each_index.map { |index| chart_dot(chart, index) },
        *chart.label_indexes.map { |index| chart_x_label(chart, index) },
        "</svg>"
      ].join.html_safe
    end

    private

    def chart_fmt(value)
      format("%.2f", value)
    end

    def chart_element(name, attributes, content = nil)
      attrs = attributes.map { |key, value| %( #{key}="#{value}") }.join
      content.nil? ? "<#{name}#{attrs}/>" : "<#{name}#{attrs}>#{content}</#{name}>"
    end

    def chart_tick(chart, index)
      tick_y = chart.tick_y(index)
      y = chart_fmt(tick_y)
      grid = { class: "lct-chart-grid", x1: chart_fmt(chart.left), x2: chart_fmt(chart.right), y1: y, y2: y }
      label = { class: "lct-chart-axis", x: chart_fmt(chart.left - 8), y: chart_fmt(tick_y + 3), "text-anchor": "end" }
      chart_element(:line, grid) + chart_element(:text, label, "$#{chart_fmt(chart.tick_value(index))}")
    end

    def chart_paths(chart)
      line = chart_line_path(chart.coords)
      paths = [chart_element(:path, class: "lct-chart-area", d: chart_area_path(chart, line))]
      if chart.comparison_coords
        paths << chart_element(:path, class: "lct-chart-line-secondary", d: chart_line_path(chart.comparison_coords))
      end
      paths << chart_element(:path, class: "lct-chart-line", d: line)
      paths.join
    end

    def chart_line_path(coords)
      coords.each_with_index.map do |(x, y), index|
        "#{index.zero? ? 'M' : 'L'}#{chart_fmt(x)},#{chart_fmt(y)}"
      end.join(" ")
    end

    def chart_area_path(chart, line)
      coords = chart.coords
      base = chart_fmt(chart.baseline)
      return "#{line} L#{chart_fmt(coords.last[0])},#{base} L#{chart_fmt(coords.first[0])},#{base} Z" if coords.size > 1

      x, y = coords.first
      "M#{chart_fmt(chart.left)},#{base} L#{chart_fmt(x)},#{chart_fmt(y)} L#{chart_fmt(chart.right)},#{base} Z"
    end

    def chart_dot(chart, index)
      point = chart.points[index]
      x, y = chart.coords[index]
      peak = index == chart.peak_index
      circle = { class: peak ? "lct-chart-peak" : "lct-chart-dot", cx: chart_fmt(x), cy: chart_fmt(y), r: peak ? 4 : 3 }
      title = ERB::Util.html_escape("#{point[:label]}: #{money(point[:cost])}")
      "<g>#{chart_element(:circle, circle)}<title>#{title}</title></g>"
    end

    def chart_x_label(chart, index)
      x, = chart.coords[index]
      anchor = chart_label_anchor(chart, index)
      attributes = { class: "lct-chart-axis", x: chart_fmt(x), y: chart_fmt(chart.height - 8), "text-anchor": anchor }
      chart_element(:text, attributes, ERB::Util.html_escape(chart.points[index][:label]))
    end

    def chart_label_anchor(chart, index)
      return "start" if index.zero?

      index == chart.points.size - 1 ? "end" : "middle"
    end
  end
end
