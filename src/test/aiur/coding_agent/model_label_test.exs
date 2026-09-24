defmodule Aiur.CodingAgent.ModelLabelTest do
  use ExUnit.Case, async: true

  alias Aiur.CodingAgent.ModelLabel

  @flags ~w(remote low medium high xhigh max)
  @sources %{"claude-repl" => "claude"}

  defp resolve(spec, dispatchable, catalogues) do
    ModelLabel.resolve(spec, dispatchable,
      flags: @flags,
      source_for: &Map.get(@sources, &1, &1),
      catalogue: fn backend -> Map.fetch!(catalogues, backend) end
    )
  end

  @claude {["opus", "sonnet", "haiku", "opus-5-5"], :discovered}
  @codex {["gpt-5.6-sol", "gpt-5.7-astra"], :discovered}

  describe "backends and flags come first" do
    test "a backend name selects that backend" do
      assert resolve("claude", ["claude", "codex"], %{}) == {:backend, "claude"}
    end

    test "remote and effort specs are flags, not selectors — including a remote variant" do
      for spec <- ["remote", "remote-opus", "high", "max"] do
        assert resolve(spec, ["claude", "codex"], %{}) == :not_a_selector
      end
    end
  end

  describe "backend-prefixed labels always select their backend" do
    test "the longest backend name wins the prefix" do
      assert resolve("claude-repl-opus", ["claude", "claude-repl"], %{}) == {:model, "claude-repl", "opus"}
    end

    test "an unlisted variant still pins, so existing version labels keep working" do
      # Only bare names consult the catalogue; a prefixed label is an explicit
      # choice of backend and never falls back.
      assert resolve("claude-opus-9-9", ["claude"], %{}) == {:model, "claude", "opus-9-9"}
      assert resolve("codex-astra", ["codex"], %{}) == {:model, "codex", "astra"}
    end
  end

  describe "bare names resolve through the catalogues" do
    test "a claude family resolves to claude, not ambiguously to claude and claude-repl" do
      assert resolve("opus", ["claude", "claude-repl", "codex"], %{"claude" => @claude, "codex" => @codex}) ==
               {:model, "claude", "opus"}
    end

    test "a family only the CLI reported resolves to its backend" do
      assert resolve("astra", ["claude", "codex"], %{"claude" => @claude, "codex" => @codex}) ==
               {:model, "codex", "astra"}
    end

    test "a claude id's family matches even when only the versioned id is listed" do
      assert resolve("opus", ["claude"], %{"claude" => {["opus-5-5"], :discovered}}) == {:model, "claude", "opus"}
    end

    test "an exact listed id resolves as given" do
      assert resolve("gpt-5.7-astra", ["codex"], %{"codex" => @codex}) == {:model, "codex", "gpt-5.7-astra"}
    end

    test "a shared catalogue resolves to its source backend whatever order the backends are listed in" do
      assert resolve("opus", ["claude-repl", "claude"], %{"claude" => @claude, "claude-repl" => @claude}) ==
               {:model, "claude", "opus"}
    end

    test "a family only counts on a backend that can expand it; an exact id counts anywhere" do
      catalogues = %{"codex" => @codex, "openrouter" => {["google/gemini-3-pro", "gemini-exact"], :discovered}}

      opts = [
        flags: @flags,
        catalogue: &Map.fetch!(catalogues, &1),
        expands_family?: &(&1 == "codex")
      ]

      # OpenRouter could not turn `gemini` into a slug, so it is not a match.
      assert ModelLabel.resolve("gemini", ["codex", "openrouter"], opts) == {:unresolved, :unknown_name, []}
      assert ModelLabel.resolve("gemini-exact", ["codex", "openrouter"], opts) == {:model, "openrouter", "gemini-exact"}
    end

    test "a shared catalogue resolves to the member that is dispatchable when its source is not" do
      assert resolve("opus", ["claude-repl"], %{"claude-repl" => @claude}) == {:model, "claude-repl", "opus"}
    end
  end

  describe "bare names that do not resolve" do
    test "a name no catalogue offers is an unknown name when every catalogue was discovered" do
      assert resolve("opsu", ["claude", "codex"], %{"claude" => @claude, "codex" => @codex}) ==
               {:unresolved, :unknown_name, []}
    end

    test "a name two catalogues offer is ambiguous and names both" do
      other = {["foo-1"], :discovered}

      assert resolve("foo", ["codex", "deepseek"], %{"codex" => {["foo"], :discovered}, "deepseek" => other}) ==
               {:unresolved, :ambiguous, ["codex", "deepseek"]}
    end

    test "an unmatched name reports the catalogues never discovered, since it may be too new" do
      assert resolve("astra", ["claude", "codex"], %{"claude" => @claude, "codex" => {["gpt-5.6-sol"], :curated_only}}) ==
               {:unresolved, :catalog_unavailable, ["codex"]}
    end

    test "a registered backend that is switched off selects nothing and is not re-read as a model" do
      catalogues = %{"openrouter" => {["deepseek/deepseek-v4"], :discovered}}

      assert ModelLabel.resolve("deepseek", ["openrouter"],
               flags: @flags,
               registered: ["openrouter", "deepseek"],
               catalogue: &Map.fetch!(catalogues, &1)
             ) == :not_a_selector
    end

    test "a backend that is not dispatchable is never matched" do
      assert resolve("astra", ["claude"], %{"claude" => @claude, "codex" => @codex}) ==
               {:unresolved, :unknown_name, []}
    end
  end
end
