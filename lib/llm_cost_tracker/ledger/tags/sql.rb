# frozen_string_literal: true

require_relative "../schema/adapter"
require_relative "../../tags/key"

module LlmCostTracker
  module Ledger
    module Tags
      module Sql
        class << self
          def value_expression(key, table_name:)
            key = LlmCostTracker::Tags::Key.validate!(key)
            connection = LlmCostTracker::Call.connection
            column = "#{table_name}.#{connection.quote_column_name('tags')}"

            if Ledger::Schema::Adapter.postgresql?(connection)
              "#{column}->>#{connection.quote(key)}"
            elsif Ledger::Schema::Adapter.mysql?(connection)
              "JSON_UNQUOTE(JSON_EXTRACT(#{column}, #{connection.quote(json_path(key))}))"
            else
              Ledger::Schema::Adapter.ensure_supported!(connection)
            end
          end

          private

          def json_path(key)
            "$.\"#{key}\""
          end
        end
      end
    end
  end
end
