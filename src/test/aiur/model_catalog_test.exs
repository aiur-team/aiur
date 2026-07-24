defmodule Aiur.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias Aiur.ModelCatalog

  test "normalizes visible Codex models" do
    assert {:ok, ["gpt-5.5", "gpt-5.6-sol"]} =
             ModelCatalog.normalize_response(%{
               "data" => [
                 %{"id" => "legacy-id", "model" => "gpt-5.6-sol", "hidden" => false},
                 %{"id" => "gpt-5.5"},
                 %{"id" => "retired", "hidden" => true}
               ]
             })
  end

  test "normalizes Claude ids and native aliases" do
    assert {:ok, ["fable", "opus", "opus-4-8"]} =
             ModelCatalog.normalize_response(%{
               "models" => [
                 %{"id" => "opus-4-8", "name" => "Claude Opus 4.8", "aliases" => ["opus"]},
                 %{"id" => "fable"}
               ]
             })
  end

  test "probe failures remain ordinary errors" do
    assert {:error, :offline} =
             ModelCatalog.models("codex", probe_fun: fn "codex" -> {:error, :offline} end)
  end
end
