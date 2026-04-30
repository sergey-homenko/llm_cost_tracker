# frozen_string_literal: true

require_relative "../schema/adapter"
require_relative "../../tags/key"

module LlmCostTracker
  module Ledger
    module Tags
      module Sql
        class << self
          def value_expression(model, key, table_name:)
            key = LlmCostTracker::Tags::Key.validate!(key)
            column = "#{table_name}.#{model.connection.quote_column_name('tags')}"

            if Ledger::Schema::Adapter.postgresql?(model.connection)
              "#{column}->>#{model.connection.quote(key)}"
            elsif Ledger::Schema::Adapter.mysql?(model.connection)
              "JSON_UNQUOTE(JSON_EXTRACT(#{column}, #{model.connection.quote(json_path(key))}))"
            else
              Ledger::Schema::Adapter.ensure_supported!(model.connection)
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
