defmodule Aiur.EnvInventoryTest do
  @moduledoc """
  Acceptance criterion 1: every environment variable the app reads is declared
  in `Aiur.Env.Schema`, whatever reference form it uses.

  The naive form is a literal read, `System.get_env("NAME")`. The trap the
  ticket calls out is the module-attribute form, where the name is bound to an
  attribute first and read through it:

      @app_id_env "GITHUB_APP_ID"
      System.get_env(@app_id_env)   # or env_value(@app_id_env) via a helper

  A grep that only matches literals reports those variables as never read and
  can confidently delete live ones. This test inventories both forms across
  `lib/` and fails on any variable absent from the schema, so a new read in
  either form cannot ship undeclared.
  """
  use ExUnit.Case, async: true

  alias Aiur.Env.Schema

  @lib_glob "lib/**/*.{ex,exs}"

  # Literal form: System.get_env("NAME") / System.fetch_env("NAME").
  @literal_re ~r/System\.(?:get_env|fetch_env)\(\s*"([A-Z][A-Z0-9_]*)"/

  # Attribute form: @attr "NAME" where NAME is an UPPER_CASE string that looks
  # like an env var. The value is required to be declared whether the attribute
  # is read directly or handed to a helper that calls System.get_env/1.
  @attr_re ~r/@([A-Za-z0-9_]+)\s+["']([A-Z][A-Z0-9_]{2,})["']/

  # UPPER_CASE string constants bound to module attributes that are NOT
  # environment variables. Each entry is a deliberate, reviewed exclusion; a
  # new one forces a conscious decision rather than silently shrinking the
  # inventory.
  @non_env_attribute_values ["APPROVED", "USD"]

  test "both reference forms are inventoried (guards against a broken matcher)" do
    # If the matcher stops seeing reads, these lower bounds catch it: the app
    # reads far more than 40 variables literally and the ticket names 9 that
    # only appear in attribute form.
    assert MapSet.size(literal_refs()) >= 40
    assert MapSet.size(attribute_refs()) >= 9
  end

  test "every env var read literally is declared in the schema" do
    missing = MapSet.difference(literal_refs(), declared_names())

    assert MapSet.size(missing) == 0,
           "env vars read via System.get_env(\"NAME\") but absent from " <>
             "Aiur.Env.Schema: #{inspect(MapSet.to_list(missing) |> Enum.sort())}"
  end

  test "every env var read through a module attribute is declared in the schema" do
    missing = MapSet.difference(attribute_refs(), declared_names())

    assert MapSet.size(missing) == 0,
           "env vars bound to module attributes but absent from Aiur.Env.Schema: " <>
             "#{inspect(MapSet.to_list(missing) |> Enum.sort())}"
  end

  test "every env var the app reads (both forms) is declared" do
    refs = MapSet.union(literal_refs(), attribute_refs())
    missing = MapSet.difference(refs, declared_names())

    assert MapSet.size(missing) == 0,
           "env vars the app reads but Aiur.Env.Schema does not declare: " <>
             "#{inspect(MapSet.to_list(missing) |> Enum.sort())}"
  end

  defp declared_names, do: MapSet.new(Schema.names())

  defp lib_files, do: Path.wildcard(@lib_glob)

  defp literal_refs do
    lib_files()
    |> Enum.flat_map(fn path -> Regex.scan(@literal_re, File.read!(path)) end)
    |> Enum.map(fn [_full, name] -> name end)
    |> MapSet.new()
  end

  defp attribute_refs do
    non_env = MapSet.new(@non_env_attribute_values)

    lib_files()
    |> Enum.flat_map(fn path ->
      Regex.scan(@attr_re, File.read!(path))
      |> Enum.map(fn [_full, _attr, value] -> value end)
      |> Enum.reject(&MapSet.member?(non_env, &1))
    end)
    |> MapSet.new()
  end
end
