# frozen_string_literal: true

module LlmCostTracker
  module SortableTableHelper
    SORT_DIRECTIONS = %w[asc desc].freeze

    def sortable_header(label, column, num: false)
      current_sort = params[:sort].to_s
      current_dir  = SORT_DIRECTIONS.include?(params[:dir].to_s) ? params[:dir].to_s : nil
      natural_dir  = num ? "desc" : "asc"

      active = current_sort == column
      effective_dir = active ? (current_dir || natural_dir) : natural_dir
      next_dir = active ? (effective_dir == "asc" ? "desc" : "asc") : natural_dir

      classes = ["lct-sortable"]
      classes << "lct-num" if num
      classes << "lct-sorted" if active

      href = dashboard_filter_path(current_query(sort: column, dir: next_dir, page: nil))
      arrow = active ? (effective_dir == "asc" ? "▲" : "▼") : "▼"
      aria_sort = active ? (effective_dir == "asc" ? "ascending" : "descending") : "none"

      tag.th(class: classes.join(" "), "aria-sort": aria_sort) do
        link_to(href) { safe_join([label, " ", tag.span(arrow, class: "lct-sort-ind")]) }
      end
    end
  end
end
