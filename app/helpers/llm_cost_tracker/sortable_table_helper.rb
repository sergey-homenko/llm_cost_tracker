# frozen_string_literal: true

module LlmCostTracker
  module SortableTableHelper
    SORT_ARROWS = { "asc" => "▲", "desc" => "▼" }.freeze
    ARIA_SORT = { "asc" => "ascending", "desc" => "descending" }.freeze

    def sortable_header(label, column, num: false, default: false)
      natural = num ? "desc" : "asc"
      direction = sorted_direction(column, natural, default)
      classes = ["lct-sortable", ("lct-num" if num), ("lct-sorted" if direction)].compact

      href = dashboard_filter_path(current_query(sort: column, dir: next_sort_direction(direction, natural), page: nil))
      tag.th(class: classes.join(" "), "aria-sort": ARIA_SORT.fetch(direction, "none")) do
        link_to(href) { safe_join([label, " ", tag.span(SORT_ARROWS.fetch(direction, "▼"), class: "lct-sort-ind")]) }
      end
    end

    private

    def sorted_direction(column, natural, default)
      return unless (params[:sort].presence || (column if default)) == column

      requested = params[:dir].to_s
      Dashboard::Sort::DIRECTIONS.include?(requested) ? requested : natural
    end

    def next_sort_direction(direction, natural)
      return natural unless direction

      direction == "asc" ? "desc" : "asc"
    end
  end
end
