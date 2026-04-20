# frozen_string_literal: true

module LlmCostTracker
  module PaginationHelper
    PER_PAGE_CHOICES = [25, 50, 100, 200].freeze

    def pagination_page_items(current, total_pages, window: 1)
      return (1..total_pages).to_a if total_pages <= (window * 2) + 5

      anchors = [1, total_pages, current, current - window, current + window]
      pages = anchors.grep(1..total_pages).uniq.sort
      pages.each_with_index.flat_map do |page, index|
        gap = index.positive? && page - pages[index - 1] > 1 ? [:gap] : []
        gap << page
      end
    end
  end
end
