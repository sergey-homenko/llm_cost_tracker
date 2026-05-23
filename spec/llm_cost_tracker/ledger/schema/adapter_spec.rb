# frozen_string_literal: true

require "spec_helper"
require "active_record"

RSpec.describe LlmCostTracker::Ledger::Schema::Adapter do
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

  describe ".json_column_errors" do
    it "returns no errors when the column is missing entirely" do
      expect(described_class.json_column_errors(nil, "PostgreSQL", "metadata")).to eq([])
    end

    it "returns no errors when a Postgres column is jsonb" do
      column = double(type: :jsonb, sql_type: "jsonb")
      expect(described_class.json_column_errors(column, "PostgreSQL", "metadata")).to eq([])
    end

    it "reports the expected adapter type when a Postgres column is plain json" do
      column = double(type: :json, sql_type: "json")
      expect(described_class.json_column_errors(column, "PostgreSQL", "metadata"))
        .to include(match(/metadata column must use jsonb \(got json\)/))
    end

    it "reports the expected adapter type when a MySQL column is text" do
      column = double(type: :text, sql_type: "text")
      expect(described_class.json_column_errors(column, "Trilogy", "details"))
        .to include(match(/details column must use json \(got text\)/))
    end
  end

  describe ".json_extract" do
    it "emits Postgres ->> operator for a static key" do
      expect(described_class.json_extract("PostgreSQL", :metadata, "provider")).to eq("metadata->>'provider'")
    end

    it "emits MySQL JSON_UNQUOTE/JSON_EXTRACT for a static key" do
      expect(described_class.json_extract("Trilogy", :metadata, "row_type"))
        .to eq("JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.row_type'))")
    end
  end

  describe ".json_extract_param" do
    it "emits Postgres ->>? template" do
      expect(described_class.json_extract_param("PostgreSQL", :metadata)).to eq("metadata->>?")
    end

    it "emits MySQL JSON_UNQUOTE/JSON_EXTRACT(?) template" do
      expect(described_class.json_extract_param("Trilogy", :metadata))
        .to eq("JSON_UNQUOTE(JSON_EXTRACT(metadata, ?))")
    end
  end

  describe ".json_path_param" do
    it "returns the bare key for Postgres" do
      expect(described_class.json_path_param("PostgreSQL", "provider_project_id")).to eq("provider_project_id")
    end

    it "prefixes the key with $. for MySQL" do
      expect(described_class.json_path_param("Trilogy", "provider_project_id")).to eq("$.provider_project_id")
    end
  end

  describe ".json_null_sql" do
    it "emits a single IS NULL check for Postgres" do
      expect(described_class.json_null_sql("PostgreSQL", :metadata, "row_type")).to eq("metadata->>'row_type' IS NULL")
    end

    it "covers both missing key and JSON null for MySQL" do
      expect(described_class.json_null_sql("Trilogy", :metadata, "row_type")).to eq(
        "JSON_EXTRACT(metadata, '$.row_type') IS NULL OR " \
        "JSON_TYPE(JSON_EXTRACT(metadata, '$.row_type')) = 'NULL'"
      )
    end
  end

  describe ".json_present_sql" do
    it "emits a single IS NOT NULL check for Postgres" do
      expect(described_class.json_present_sql("PostgreSQL", :metadata, "row_type"))
        .to eq("metadata->>'row_type' IS NOT NULL")
    end

    it "excludes JSON null for MySQL" do
      expect(described_class.json_present_sql("Trilogy", :metadata, "row_type")).to eq(
        "JSON_EXTRACT(metadata, '$.row_type') IS NOT NULL AND " \
        "JSON_TYPE(JSON_EXTRACT(metadata, '$.row_type')) <> 'NULL'"
      )
    end
  end

  describe ".apply_json_contains" do
    it "uses Postgres @> containment operator with a single jsonb-cast parameter" do
      relation = double("relation")
      expect(relation).to receive(:where).with("metadata @> ?::jsonb", '{"provider":"openai"}').and_return(:next)
      result = described_class.apply_json_contains("PostgreSQL", relation, :metadata, "provider" => "openai")
      expect(result).to eq(:next)
    end

    it "chains per-key extract equality on MySQL" do
      step1 = double("step1")
      step2 = double("step2")
      expect(step1).to receive(:where)
        .with("JSON_UNQUOTE(JSON_EXTRACT(metadata, ?)) = ?", "$.provider", "openai").and_return(step2)
      expect(step2).to receive(:where)
        .with("JSON_UNQUOTE(JSON_EXTRACT(metadata, ?)) = ?", "$.source", "csv").and_return(:final)
      result = described_class.apply_json_contains("Trilogy", step1, :metadata,
                                                   "provider" => "openai", "source" => "csv")
      expect(result).to eq(:final)
    end
  end

  def connection_instance(adapter_class, adapter_name)
    Class.new(adapter_class) do
      define_method(:adapter_name) { adapter_name }
    end.allocate
  end
end
