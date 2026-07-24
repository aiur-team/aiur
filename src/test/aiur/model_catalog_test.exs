defmodule Aiur.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias Aiur.ModelCatalog

  defp probe(payload), do: [probe: fn _family, _opts -> payload end]

  describe "discover/2 — codex app-server shape" do
    test "reads the advertised model ids in the order the provider lists them" do
      payload =
        {:ok,
         %{
           "data" => [
             %{"id" => "gpt-5.6-sol", "model" => "gpt-5.6-sol", "isDefault" => true},
             %{"id" => "gpt-5.5", "model" => "gpt-5.5", "isDefault" => false}
           ]
         }}

      assert ModelCatalog.discover("codex", probe(payload)) == {:ok, ["gpt-5.6-sol", "gpt-5.5"]}
    end

    test "withholds models codex hides from its own picker" do
      payload =
        {:ok,
         %{
           "data" => [
             %{"model" => "gpt-5.6-sol", "hidden" => false},
             %{"model" => "gpt-internal-eval", "hidden" => true}
           ]
         }}

      assert ModelCatalog.discover("codex", probe(payload)) == {:ok, ["gpt-5.6-sol"]}
    end

    test "a model absent from the registry is still reported, which is what makes init self-updating" do
      payload = {:ok, %{"data" => [%{"model" => "gpt-9.9-nova"}]}}

      assert {:ok, discovered} = ModelCatalog.discover("codex", probe(payload))
      assert "gpt-9.9-nova" in discovered
      refute Aiur.CodingAgent.known_model?("codex", "gpt-9.9-nova")
    end
  end

  describe "discover/2 — claude app-server shape" do
    test "reports the generic alias and the model:claude-<variant> spelling of each id" do
      payload =
        {:ok,
         %{
           "models" => [
             %{"id" => "claude-opus-4-6", "name" => "Claude Opus 4.6", "aliases" => ["opus"]},
             %{"id" => "claude-haiku-4-5", "name" => "Claude Haiku 4.5", "aliases" => ["haiku"]}
           ]
         }}

      assert ModelCatalog.discover("claude", probe(payload)) ==
               {:ok, ["opus", "opus-4-6", "haiku", "haiku-4-5"]}
    end

    test "claude-repl shares the claude CLI, so it discovers the same models" do
      payload = {:ok, %{"models" => [%{"id" => "claude-opus-4-6", "aliases" => ["opus"]}]}}

      assert ModelCatalog.discover("claude-repl", probe(payload)) == {:ok, ["opus", "opus-4-6"]}
    end
  end

  describe "discover/2 degradation" do
    test "a probe failure is returned, never raised — init has to survive being offline" do
      assert ModelCatalog.discover("codex", probe({:error, :model_list_timeout})) ==
               {:error, :model_list_timeout}

      assert ModelCatalog.discover("codex", probe({:error, {:cli_unavailable, "codex"}})) ==
               {:error, {:cli_unavailable, "codex"}}
    end

    test "an answer in an unrecognized shape is an error, not an empty catalogue" do
      # Reporting `{:ok, []}` here would read as "aiur is already current" and
      # silently stop offering new tags forever.
      assert ModelCatalog.discover("codex", probe({:ok, %{"unexpected" => true}})) ==
               {:error, {:unexpected_model_list, "codex"}}
    end

    test "an unknown backend has no CLI to ask" do
      assert ModelCatalog.discover("nope") == {:error, {:unknown_backend, "nope"}}
    end
  end
end
