# frozen_string_literal: true

module LlmCostTracker
  module Ingestion
    module Pool
      DEFAULT_POOL_SIZE = 2
      MUTEX = Mutex.new

      class << self
        def with_connection(&)
          pool.with_connection(&)
        end

        def pool
          @pool || MUTEX.synchronize { @pool ||= build_pool }
        end

        def reset!
          MUTEX.synchronize do
            @pool&.disconnect!
            @pool = nil
            @handler = nil
          end
        end

        private

        def build_pool
          @handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
          @handler.establish_connection(connection_config)
        end

        def connection_config
          LlmCostTracker::Call.connection_db_config.configuration_hash.merge(pool: pool_size)
        end

        def pool_size
          configured = LlmCostTracker.configuration.durable_ingestion_pool_size.to_i
          configured.positive? ? configured : DEFAULT_POOL_SIZE
        end
      end
    end
  end
end
