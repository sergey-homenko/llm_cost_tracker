# frozen_string_literal: true

module LlmCostTracker
  # Server-rendered inline SVG helpers for the dashboard.
  # Keeps the dashboard JS-free while still producing a real chart.
  module ChartHelper
    # Build a compact SVG spend chart from a time series of
    # `{ label:, cost: }` points. Returns html-safe SVG markup.
    def spend_chart_svg(points, height: 180, y_ticks: 3)
      return nil if points.blank?

      cfg = chart_config(points, height, y_ticks)
      parts = [chart_svg_open(cfg)]
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

    def chart_config(points, height, y_ticks)
      width = 720
      pad = { top: 16, right: 16, bottom: 28, left: 56 }
      plot_w = width - pad[:left] - pad[:right]
      plot_h = height - pad[:top] - pad[:bottom]
      max_cost = [points.map { |p| p[:cost].to_f }.max.to_f, 0.0001].max
      n = points.size
      step = n > 1 ? plot_w.to_f / (n - 1) : 0.0
      coords = points.each_with_index.map do |p, i|
        x = pad[:left] + (i * step)
        y = pad[:top] + plot_h - ((p[:cost].to_f / max_cost) * plot_h)
        [x, y]
      end

      { width: width, height: height, pad: pad, plot_w: plot_w, plot_h: plot_h,
        max_cost: max_cost, n: n, y_ticks: y_ticks, points: points, coords: coords }
    end

    def chart_svg_open(cfg)
      attrs = [
        %(class="lct-chart"),
        %(viewBox="0 0 #{cfg[:width]} #{cfg[:height]}"),
        %(preserveAspectRatio="none"),
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
      coords = cfg[:coords]
      line = coords.each_with_index.map do |(x, y), i|
        "#{i.zero? ? 'M' : 'L'}#{chart_fmt(x)},#{chart_fmt(y)}"
      end.join(" ")
      base_y = cfg[:pad][:top] + cfg[:plot_h]
      area = build_area_path(coords, cfg, base_y, line)
      %(<path class="lct-chart-area" d="#{area}"/><path class="lct-chart-line" d="#{line}"/>)
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
      circle = %(<circle class="lct-chart-dot" cx="#{chart_fmt(pt_x)}" cy="#{chart_fmt(pt_y)}" r="3"/>)
      "<g>#{circle}<title>#{title}</title></g>"
    end

    def chart_x_labels(cfg)
      indexes = cfg[:n] <= 2 ? (0...cfg[:n]).to_a : [0, cfg[:n] / 2, cfg[:n] - 1].uniq
      label_y = chart_fmt(cfg[:height] - 8)
      indexes.map { |idx| chart_x_label(cfg, idx, label_y) }
    end

    def chart_x_label(cfg, idx, label_y)
      pt_x, = cfg[:coords][idx]
      label = ERB::Util.html_escape(cfg[:points][idx][:label])
      %(<text class="lct-chart-axis" x="#{chart_fmt(pt_x)}" y="#{label_y}" text-anchor="middle">#{label}</text>)
    end
  end
end
