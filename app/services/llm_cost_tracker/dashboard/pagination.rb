# frozen_string_literal: true

module LlmCostTracker
  module Dashboard
    class Pagination
      DEFAULT_PER = 50
      MAX_PER = 200
      MIN_PAGE = 1
      MAX_PAGE = 100_000
      MIN_PER = 1

      attr_reader :page, :per

      def self.call(params)
        params = Params.to_hash(params).symbolize_keys
        new(
          page: integer_param(params, :page, default: MIN_PAGE, min: MIN_PAGE, max: MAX_PAGE),
          per: integer_param(params, :per, default: DEFAULT_PER, min: MIN_PER, max: MAX_PER)
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

      def offset
        (page - 1) * per
      end

      def prev_page?
        page > MIN_PAGE
      end

      def next_page?(total_count)
        total_count = total_count.to_i
        offset + per < total_count
      end

      def total_pages(total_count)
        total_count = total_count.to_i
        return MIN_PAGE unless total_count.positive?

        ((total_count + per - 1) / per)
      end
    end
  end
end
