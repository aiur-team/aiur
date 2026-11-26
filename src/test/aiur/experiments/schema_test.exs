defmodule Aiur.Experiments.SchemaTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.Schema

  test "v1 passes through unchanged" do
    spec = %{"schema_version" => 1, "title" => "Experiment", "registered_at" => "2026-10-09T00:00:00Z"}
    assert Schema.current() == 1
    assert Schema.migrate(spec) == {:ok, spec}
  end

  test "pre-release v0 adds registration marker without losing fields" do
    assert Schema.migrate(%{"schema_version" => 0, "title" => "Draft"}) == {:ok, %{"schema_version" => 1, "title" => "Draft", "registered_at" => nil}}
  end

  test "newer and unsupported versions are rejected" do
    assert Schema.migrate(%{"schema_version" => 2}) == {:error, {:newer_version, 2}}
    assert Schema.migrate(%{"schema_version" => -1}) == {:error, :unsupported_schema_version}
    assert Schema.migrate(%{}) == {:error, :unsupported_schema_version}
  end
end
