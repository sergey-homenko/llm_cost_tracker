# frozen_string_literal: true

module LlmCostTracker
  class Pagination
    DEFAULT_PER = 50
    MAX_PER = 200
    MIN_PAGE = 1

    attr_reader :page, :per

    def self.call(params)
      params = LlmCostTracker::ParameterHash.with_indifferent_access(params)
      new(
        page: integer_param(params, :page, default: MIN_PAGE, min: MIN_PAGE),
        per: integer_param(params, :per, default: DEFAULT_PER, min: 1, max: MAX_PER)
      )
    end

    def self.integer_param(params, key, default:, min:, max: nil)
      value = Integer(params[key], 10)
      value = [value, min].max
      value = [value, max].min if max
      value
    rescue ArgumentError, TypeError
      default
    end
    private_class_method :integer_param

    def initialize(page:, per:)
      @page = page
      @per = per
      freeze
    end

    def limit
      per
    end

    def offset
      (page - 1) * per
    end

    def prev_page?
      page > MIN_PAGE
    end

    def next_page?(total_count)
      offset + per < total_count.to_i
    end

    def total_pages(total_count)
      return MIN_PAGE if total_count.to_i <= 0

      [(total_count.to_f / per).ceil, MIN_PAGE].max
    end
  end
end
