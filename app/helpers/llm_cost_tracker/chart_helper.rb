# frozen_string_literal: true

module LlmCostTracker
  module ChartHelper
    def spend_chart_svg(points, comparison_points: nil, height: 180, y_ticks: 3)
      return nil if points.blank?

      cfg = chart_config(points, comparison_points, height, y_ticks)
      parts = [chart_svg_open(cfg), "<title>Daily spend trend</title>", chart_area_gradient_def]
      parts.concat(chart_grid_and_axis(cfg))
      parts << chart_paths(cfg)
      parts.concat(chart_dots(cfg))
      parts.concat(chart_x_labels(cfg))
      parts << "</svg>"
      parts.join.html_safe
    end

    private

    def chart_fmt(value)
      format("%.2f", value)
    end

    def chart_config(points, comparison_points, height, y_ticks)
      width = 1180
      pad = { top: 16, right: 16, bottom: 28, left: 56 }
      plot_w = width - pad[:left] - pad[:right]
      plot_h = height - pad[:top] - pad[:bottom]
      all_costs = points.map { |p| p[:cost].to_f } + Array(comparison_points).map { |p| p[:cost].to_f }
      max_cost = [all_costs.max.to_f, 0.0001].max
      coords = chart_coords(points, pad, plot_w, plot_h, max_cost)
      comparison_coords = chart_coords(comparison_points, pad, plot_w, plot_h, max_cost) if comparison_points.present?

      peak_index = points.each_with_index.max_by { |point, _| point[:cost].to_f }&.last
      { width: width, height: height, pad: pad, plot_w: plot_w, plot_h: plot_h,
        max_cost: max_cost, n: points.size, y_ticks: y_ticks, points: points, coords: coords,
        comparison_points: comparison_points, comparison_coords: comparison_coords,
        peak_index: peak_index }
    end

    def chart_coords(points, pad, plot_w, plot_h, max_cost)
      n = points.size
      step = n > 1 ? plot_w.to_f / (n - 1) : 0.0

      points.each_with_index.map do |point, idx|
        x = pad[:left] + (idx * step)
        y = pad[:top] + plot_h - ((point[:cost].to_f / max_cost) * plot_h)
        [x, y]
      end
    end

    def chart_svg_open(cfg)
      attrs = [
        %(class="lct-chart"),
        %(viewBox="0 0 #{cfg[:width]} #{cfg[:height]}"),
        %(preserveAspectRatio="xMidYMid meet"),
        %(role="img"),
        %(aria-label="Daily spend trend")
      ].join(" ")
      "<svg #{attrs}>"
    end

    def chart_grid_and_axis(cfg)
      (0..cfg[:y_ticks]).map { |i| chart_tick_line(cfg, i) }
    end

    def chart_tick_line(cfg, idx)
      pad = cfg[:pad]
      right_x = chart_fmt(pad[:left] + cfg[:plot_w])
      left_x = chart_fmt(pad[:left])
      text_x = chart_fmt(pad[:left] - 8)
      value = cfg[:max_cost] * (cfg[:y_ticks] - idx).to_f / cfg[:y_ticks]
      y = chart_fmt(pad[:top] + (cfg[:plot_h] * idx.to_f / cfg[:y_ticks]))
      label_y = chart_fmt(pad[:top] + (cfg[:plot_h] * idx.to_f / cfg[:y_ticks]) + 3)
      grid = %(<line class="lct-chart-grid" x1="#{left_x}" x2="#{right_x}" y1="#{y}" y2="#{y}"/>)
      label = format("%.2f", value)
      text = %(<text class="lct-chart-axis" x="#{text_x}" y="#{label_y}" text-anchor="end">$#{label}</text>)
      "#{grid}#{text}"
    end

    def chart_paths(cfg)
      line = build_line_path(cfg[:coords])
      base_y = cfg[:pad][:top] + cfg[:plot_h]
      area = build_area_path(cfg[:coords], cfg, base_y, line)
      secondary = if cfg[:comparison_coords].present?
                    %(<path class="lct-chart-line-secondary" d="#{build_line_path(cfg[:comparison_coords])}"/>)
                  else
                    ""
                  end
      %(<path class="lct-chart-area" d="#{area}"/>#{secondary}<path class="lct-chart-line" d="#{line}"/>)
    end

    def build_line_path(coords)
      coords.each_with_index.map do |(x, y), idx|
        "#{idx.zero? ? 'M' : 'L'}#{chart_fmt(x)},#{chart_fmt(y)}"
      end.join(" ")
    end

    def build_area_path(coords, cfg, base_y, line)
      if coords.size == 1
        x, y = coords.first
        left = chart_fmt(cfg[:pad][:left])
        right = chart_fmt(cfg[:pad][:left] + cfg[:plot_w])
        "M#{left},#{chart_fmt(base_y)} L#{chart_fmt(x)},#{chart_fmt(y)} L#{right},#{chart_fmt(base_y)} Z"
      else
        first_x = chart_fmt(coords.first[0])
        last_x = chart_fmt(coords.last[0])
        "#{line} L#{last_x},#{chart_fmt(base_y)} L#{first_x},#{chart_fmt(base_y)} Z"
      end
    end

    def chart_dots(cfg)
      cfg[:coords].each_with_index.map { |(pt_x, pt_y), idx| chart_dot(cfg, pt_x, pt_y, idx) }
    end

    def chart_dot(cfg, pt_x, pt_y, idx)
      point = cfg[:points][idx]
      title = ERB::Util.html_escape("#{point[:label]}: #{money(point[:cost])}")
      peak = idx == cfg[:peak_index]
      klass = peak ? "lct-chart-peak" : "lct-chart-dot"
      radius = peak ? 4 : 3
      circle = %(<circle class="#{klass}" cx="#{chart_fmt(pt_x)}" cy="#{chart_fmt(pt_y)}" r="#{radius}"/>)
      "<g>#{circle}<title>#{title}</title></g>"
    end

    def chart_area_gradient_def
      "<defs><linearGradient id=\"lct-chart-grad\" x1=\"0\" x2=\"0\" y1=\"0\" y2=\"1\">" \
        "<stop offset=\"0%\" stop-color=\"var(--lct-accent)\" stop-opacity=\"0.28\"/>" \
        "<stop offset=\"100%\" stop-color=\"var(--lct-accent)\" stop-opacity=\"0.02\"/>" \
        "</linearGradient></defs>"
    end

    def chart_x_labels(cfg)
      indexes = cfg[:n] <= 2 ? (0...cfg[:n]).to_a : [0, cfg[:n] / 2, cfg[:n] - 1].uniq
      label_y = chart_fmt(cfg[:height] - 8)
      indexes.map { |idx| chart_x_label(cfg, idx, label_y) }
    end

    def chart_x_label(cfg, idx, label_y)
      pt_x, = cfg[:coords][idx]
      label = ERB::Util.html_escape(cfg[:points][idx][:label])
      anchor = if idx.zero? then "start"
               elsif idx == cfg[:n] - 1 then "end"
               else "middle"
               end
      %(<text class="lct-chart-axis" x="#{chart_fmt(pt_x)}" y="#{label_y}" text-anchor="#{anchor}">#{label}</text>)
    end
  end
end
