# frozen_string_literal: true

module LlmCostTracker
  module SortableTableHelper
    def sortable_header(label, column, num: false, default: false)
      state = sortable_state(column, num: num, default: default)
      classes = ["lct-sortable"]
      classes << "lct-num" if num
      classes << "lct-sorted" if state[:active]

      href = dashboard_filter_path(current_query(sort: column, dir: state[:next_dir], page: nil))
      tag.th(class: classes.join(" "), "aria-sort": state[:aria_sort]) do
        link_to(href) { safe_join([label, " ", tag.span(state[:arrow], class: "lct-sort-ind")]) }
      end
    end

    private

    def sortable_state(column, num:, default: false)
      current_sort = params[:sort].presence || (default ? column : nil)
      current_dir = Dashboard::Sort::DIRECTIONS.include?(params[:dir].to_s) ? params[:dir].to_s : nil
      natural_dir = num ? "desc" : "asc"
      active = current_sort == column
      effective_dir = active ? (current_dir || natural_dir) : natural_dir
      flipped = effective_dir == "asc" ? "desc" : "asc"

      {
        active: active,
        next_dir: active ? flipped : natural_dir,
        arrow: active && effective_dir == "asc" ? "▲" : "▼",
        aria_sort: sortable_aria(active, effective_dir)
      }
    end

    def sortable_aria(active, effective_dir)
      return "none" unless active

      effective_dir == "asc" ? "ascending" : "descending"
    end
  end
end
