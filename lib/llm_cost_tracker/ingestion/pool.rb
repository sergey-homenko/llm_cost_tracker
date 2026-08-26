# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

module LlmCostTracker
  module Ingestion
    module Pool
      DEFAULT_POOL_SIZE = 2
      MUTEX = Mutex.new

      class << self
        delegate :with_connection, to: :pool

        def pool
          return @pool if @pool && @pid == Process.pid

          MUTEX.synchronize do
            next @pool if @pool && @pid == Process.pid

            @pid = Process.pid
            @pool = connect!
          end
        end

        private

        def connect!
          @handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
          @handler.establish_connection(connection_config)
        end

        def connection_config
          LlmCostTracker::Call.connection_db_config.configuration_hash.merge(pool: pool_size)
        end

        def pool_size
          configured = LlmCostTracker.configuration.ingestion.pool_size.to_i
          configured.positive? ? configured : DEFAULT_POOL_SIZE
        end
      end
    end
  end
end
