# frozen_string_literal: true

module LlmCostTracker
  module DashboardFilterOptionsHelper
    def provider_filter_options(filter_params: params)
      dashboard_filter_options(column: :provider, except: :provider, filter_params: filter_params)
    end

    def model_filter_options(filter_params: params)
      dashboard_filter_options(column: :model, except: :model, filter_params: filter_params)
    end

    def dashboard_filter_value(key, fallback: nil, filter_params: params)
      source = dashboard_filter_source(filter_params)
      value = source[key.to_s] || source[key.to_sym]
      value.present? ? value : fallback
    end

    private

    def dashboard_filter_options(column:, except:, filter_params:)
      values = LlmCostTracker::Dashboard::Filter.call(
        params: option_filter_params(except: except, filter_params: filter_params)
      ).where.not(column => [nil, ""]).distinct.order(column).pluck(column)
      current = dashboard_filter_value(except, filter_params: filter_params)
      values.unshift(current) if current.present? && !values.include?(current)
      values
    end

    def option_filter_params(except:, filter_params:)
      dashboard_filter_source(filter_params).stringify_keys.merge(
        except.to_s => nil,
        "format" => nil,
        "page" => nil,
        "per" => nil,
        "sort" => nil
      )
    end

    def dashboard_filter_source(filter_params)
      source = filter_params
      return source.to_unsafe_h if source.respond_to?(:to_unsafe_h)
      return source.to_h if source.respond_to?(:to_h)

      {}
    rescue NoMethodError
      {}
    end
  end
end
