# frozen_string_literal: true

require "active_record"

module LlmCostTrackerDatabase
  class << self
    def establish!
      ensure_database!
      ActiveRecord::Base.establish_connection(config)
      LlmCostTracker::Ledger::DatabaseAdapter.ensure_supported!(ActiveRecord::Base.connection)
    end

    def disconnect!
      ActiveRecord::Base.connection.disconnect! if ActiveRecord::Base.connected?
    end

    def config
      {
        adapter: adapter,
        host: ENV.fetch("LCT_TEST_HOST", "127.0.0.1"),
        port: Integer(ENV.fetch("LCT_TEST_PORT", "5432")),
        username: ENV.fetch("LCT_TEST_USERNAME", "postgres"),
        password: ENV.fetch("LCT_TEST_PASSWORD", "password"),
        database: ENV.fetch("LCT_TEST_DATABASE", "llm_cost_tracker_test"),
        pool: Integer(ENV.fetch("LCT_TEST_POOL", "10")),
        checkout_timeout: Integer(ENV.fetch("LCT_TEST_CHECKOUT_TIMEOUT", "5"))
      }
    end

    def adapter
      ENV.fetch("LCT_TEST_ADAPTER", "postgresql")
    end

    private

    def ensure_database!
      return if @ensured

      load_adapter!
      create_database_unless_exists!
      @ensured = true
    end

    def load_adapter!
      case adapter
      when "postgresql"
        require "pg"
      when "trilogy"
        require "active_record/connection_adapters/trilogy_adapter"
        require "trilogy"
      else
        raise "Unsupported LCT_TEST_ADAPTER=#{adapter.inspect}. Use postgresql or trilogy."
      end
    end

    def create_database_unless_exists!
      if adapter == "postgresql"
        create_postgresql_database_unless_exists!
      else
        create_mysql_database_unless_exists!
      end
    ensure
      ActiveRecord::Base.connection_handler.clear_all_connections!
    end

    def create_postgresql_database_unless_exists!
      ActiveRecord::Base.establish_connection(config.merge(database: ENV.fetch("LCT_TEST_ADMIN_DATABASE", "postgres")))
      database = config.fetch(:database)
      exists = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(["SELECT 1 FROM pg_database WHERE datname = ?", database])
      )
      ActiveRecord::Base.connection.create_database(database) unless exists
    end

    def create_mysql_database_unless_exists!
      ActiveRecord::Base.establish_connection(config.merge(database: ENV.fetch("LCT_TEST_ADMIN_DATABASE", "mysql")))
      database = config.fetch(:database)
      ActiveRecord::Base.connection.execute(
        "CREATE DATABASE IF NOT EXISTS `#{database}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
      )
    end
  end
end
