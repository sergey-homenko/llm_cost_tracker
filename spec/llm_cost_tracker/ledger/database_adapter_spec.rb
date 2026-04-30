# frozen_string_literal: true

require "spec_helper"
require "active_record"

RSpec.describe LlmCostTracker::Ledger::DatabaseAdapter do
  it "detects known database families from adapter class ancestry" do
    mysql_adapter = Class.new
    postgresql_adapter = Class.new
    stub_const("ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter", mysql_adapter)
    stub_const("ActiveRecord::ConnectionAdapters::PostgreSQLAdapter", postgresql_adapter)

    mysql_connection = connection_instance(mysql_adapter, "CustomAdapter")
    postgresql_connection = connection_instance(postgresql_adapter, "CustomAdapter")

    expect(described_class.mysql?(mysql_connection)).to be true
    expect(described_class.postgresql?(postgresql_connection)).to be true
    expect(described_class.mysql?(postgresql_connection)).to be false
    expect(described_class.postgresql?(mysql_connection)).to be false
  end

  it "falls back to adapter_name for compatible third-party adapters" do
    expect(described_class.mysql?("MariaDB")).to be true
    expect(described_class.mysql?("Trilogy")).to be true
    expect(described_class.postgresql?("PostGIS")).to be false
    expect(described_class.postgresql?("PostgreSQL")).to be true
  end

  it "allows only PostgreSQL and MySQL-family adapters" do
    expect { described_class.ensure_supported!("PostgreSQL") }.not_to raise_error
    expect { described_class.ensure_supported!("Trilogy") }.not_to raise_error
    expect { described_class.ensure_supported!("SQLite3") }
      .to raise_error(LlmCostTracker::Error, /Use PostgreSQL or MySQL/)
  end

  def connection_instance(adapter_class, adapter_name)
    Class.new(adapter_class) do
      define_method(:adapter_name) { adapter_name }
    end.allocate
  end
end
