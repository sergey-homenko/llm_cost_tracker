# frozen_string_literal: true

module LlmCostTracker
  module Storage
    class ActiveRecordStore
      class << self
        def reset!
          remove_instance_variable(:@monthly_totals_enabled) if instance_variable_defined?(:@monthly_totals_enabled)
        end

        def save(event)
          tags = stringify_tags(event.tags || {})

          attributes = {
            provider:      event.provider,
            model:         event.model,
            input_tokens:  event.input_tokens,
            output_tokens: event.output_tokens,
            total_tokens:  event.total_tokens,
            input_cost:    event.cost&.input_cost,
            output_cost:   event.cost&.output_cost,
            total_cost:    event.cost&.total_cost,
            tags:          tags_for_storage(tags),
            tracked_at:    event.tracked_at
          }
          attributes[:latency_ms] = event.latency_ms if LlmCostTracker::LlmApiCall.latency_column?
          attributes[:stream] = event.stream if LlmCostTracker::LlmApiCall.stream_column?
          attributes[:usage_source] = event.usage_source if LlmCostTracker::LlmApiCall.usage_source_column?
          if LlmCostTracker::LlmApiCall.provider_response_id_column?
            attributes[:provider_response_id] = event.provider_response_id
          end

          LlmCostTracker::LlmApiCall.transaction do
            call = LlmCostTracker::LlmApiCall.create!(attributes)
            increment_monthly_total(event)
            call
          end
        end

        def monthly_total(time: Time.now.utc)
          if monthly_totals_enabled?
            monthly_total_model.where(month_start: month_start_for(time)).pick(:total_cost).to_f
          else
            LlmCostTracker::LlmApiCall
              .where(tracked_at: time.beginning_of_month..time)
              .sum(:total_cost)
              .to_f
          end
        end

        private

        def increment_monthly_total(event)
          return unless monthly_totals_enabled?
          return unless event.cost&.total_cost

          monthly_total_model.upsert_all(
            [
              {
                month_start: month_start_for(event.tracked_at),
                total_cost: event.cost.total_cost
              }
            ],
            on_duplicate: monthly_total_upsert_sql,
            record_timestamps: true,
            unique_by: monthly_total_unique_by
          )
        end

        def monthly_totals_enabled?
          return @monthly_totals_enabled unless @monthly_totals_enabled.nil?

          @monthly_totals_enabled =
            LlmCostTracker::LlmApiCall.connection.data_source_exists?("llm_cost_tracker_monthly_totals")
        end

        def monthly_total_model
          require_relative "../monthly_total" unless defined?(LlmCostTracker::MonthlyTotal)

          LlmCostTracker::MonthlyTotal
        end

        def month_start_for(time)
          time.to_time.utc.beginning_of_month.to_date
        end

        def monthly_total_unique_by
          return unless monthly_total_model.connection.supports_insert_conflict_target?

          :month_start
        end

        def monthly_total_upsert_sql
          Arel.sql(case monthly_total_model.connection.adapter_name
                   when /mysql/i
                     mysql_upsert_sql
                   else
                     "total_cost = total_cost + excluded.total_cost, updated_at = excluded.updated_at"
                   end)
        end

        def mysql_upsert_sql
          connection = monthly_total_model.connection
          if connection.respond_to?(:supports_insert_raw_alias_syntax?, true) &&
             connection.send(:supports_insert_raw_alias_syntax?)
            values_reference = connection.quote_table_name("#{monthly_total_model.table_name}_values")
            "total_cost = total_cost + #{values_reference}.total_cost, updated_at = #{values_reference}.updated_at"
          else
            "total_cost = total_cost + VALUES(total_cost), updated_at = VALUES(updated_at)"
          end
        end

        def stringify_tags(tags)
          tags.transform_keys(&:to_s).transform_values { |value| stringify_tag_value(value) }
        end

        def tags_for_storage(tags)
          LlmCostTracker::LlmApiCall.tags_json_column? ? tags : tags.to_json
        end

        def stringify_tag_value(value)
          return value.transform_values { |nested| stringify_tag_value(nested) } if value.is_a?(Hash)

          value.to_s
        end
      end
    end
  end
end
