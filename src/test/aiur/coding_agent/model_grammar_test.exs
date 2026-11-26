defmodule Aiur.CodingAgent.ModelGrammarTest do
  use ExUnit.Case, async: true

  alias Aiur.CodingAgent
  alias Aiur.Issue

  defp issue(labels), do: %Issue{labels: labels}

  describe "bare model labels resolve through the installed CLIs' catalogues" do
    @catalogues %{
      "claude" => {["opus", "sonnet", "haiku", "opus-5-5"], :discovered},
      "codex" => {["gpt-5.6-sol", "gpt-5.7-astra"], :discovered}
    }

    defp catalogue(backend), do: Map.get(@catalogues, backend, {[], :discovered})

    test "a claude family with no backend prefix selects claude and passes the alias through" do
      issue = issue(["model:opus"])

      assert CodingAgent.backend_for(issue, catalogue: &catalogue/1) == "claude"
      assert CodingAgent.model_for(issue, catalogue: &catalogue/1) == "opus"
      assert CodingAgent.model_label_status(issue, catalogue: &catalogue/1) == nil
    end

    test "a family only the codex CLI reported selects codex and resolves to its newest id" do
      issue = issue(["model:astra"])

      assert CodingAgent.backend_for(issue, catalogue: &catalogue/1) == "codex"
      assert CodingAgent.model_for(issue, catalogue: &catalogue/1) == "astra"
      assert CodingAgent.resolve_model("codex", "astra", cached_models: fn "codex" -> ["gpt-5.7-astra"] end) == "gpt-5.7-astra"
    end

    test "an unresolvable bare label is ignored for routing and reported with its cause" do
      issue = issue(["model:opsu", "agent:todo"])

      assert CodingAgent.override_backend(issue, catalogue: &catalogue/1) == nil
      assert CodingAgent.backend_for(issue, catalogue: &catalogue/1) == CodingAgent.backend_for(issue(["agent:todo"]))
      assert CodingAgent.model_label_status(issue, catalogue: &catalogue/1) == {"model:opsu", :unknown_name, []}
    end

    test "a family on a backend with no CLI catalogue is not a match, so it cannot reach that provider verbatim" do
      # `fake` is dispatchable in the test build but has no CLI `model/list`.
      catalogues = Map.put(@catalogues, "fake", {["gpt-9.9-zeta"], :discovered})
      read = fn backend -> Map.get(catalogues, backend, {[], :discovered}) end

      assert CodingAgent.override_backend(issue(["model:zeta"]), catalogue: read) == nil
      assert CodingAgent.override_backend(issue(["model:gpt-9.9-zeta"]), catalogue: read) == "fake"
    end

    test "a prefixed label with an unlisted variant still pins its backend" do
      issue = issue(["model:claude-opus-9-9"])

      assert CodingAgent.backend_for(issue, catalogue: &catalogue/1) == "claude"
      assert CodingAgent.model_for(issue, catalogue: &catalogue/1) == "opus-9-9"
      assert CodingAgent.model_label_status(issue, catalogue: &catalogue/1) == nil
    end
  end

  describe "resolve_model/3 for a CLI-catalogued derived backend" do
    test "a routed family follows a version the CLI reports but the registry does not" do
      assert CodingAgent.resolve_model("codex", "sol", cached_models: fn _ -> ["gpt-5.7-sol"] end) == "gpt-5.7-sol"
    end

    test "with an empty cache a family still resolves to a concrete id, never the bare alias" do
      # The merged list must hold concrete ids only: a derived alias in it would
      # make `Models.latest/2` treat `sol` as a pin and hand codex a bare `sol`.
      assert CodingAgent.resolve_model("codex", "sol", cached_models: fn _ -> [] end) == "gpt-5.6-sol"
    end

    test "an HTTP-catalogued derived backend ignores discovered ids" do
      newer = fn _ -> ["anthropic/claude-sonnet-9"] end

      assert CodingAgent.resolve_model("openrouter", "claude", cached_models: newer) ==
               CodingAgent.resolve_model("openrouter", "claude", cached_models: fn _ -> [] end)
    end
  end

  describe "override_effort_labels/0" do
    test "yields one model:<effort> label per supported effort" do
      assert CodingAgent.override_effort_labels() ==
               ["model:low", "model:medium", "model:high", "model:xhigh", "model:max"]
    end

    test "override_labels/0 seeds the effort labels" do
      labels = CodingAgent.override_labels()
      assert "model:low" in labels
      assert "model:xhigh" in labels
      assert "model:max" in labels
    end
  end

  describe "generic model aliases" do
    test "codex gets a derived family alias per tier because its CLI has none" do
      aliases = CodingAgent.model_aliases("codex")
      assert "sol" in aliases
      assert "terra" in aliases
      assert "luna" in aliases
    end

    test "claude has no derived aliases — its own CLI resolves opus/sonnet/haiku" do
      # Re-pointing `opus` at whichever version this registry lists would
      # reintroduce exactly the staleness the alias exists to avoid.
      assert CodingAgent.model_aliases("claude") == []
      assert CodingAgent.model_aliases("claude-repl") == []
    end

    test "a generic codex tag resolves to the newest version in that family" do
      resolved = CodingAgent.resolve_model("codex", "sol")
      assert resolved != "sol"
      assert String.ends_with?(resolved, "-sol")
      assert resolved == Enum.find(CodingAgent.backends()["codex"].models, &String.ends_with?(&1, "-sol"))
    end

    test "an explicitly pinned codex model still pins" do
      assert CodingAgent.resolve_model("codex", "gpt-5.4") == "gpt-5.4"
    end

    test "a claude alias passes through untouched so the claude CLI resolves it" do
      assert CodingAgent.resolve_model("claude", "opus") == "opus"
      assert CodingAgent.resolve_model("claude-repl", "opus") == "opus"
    end

    test "a model this build has never heard of passes through rather than being swapped" do
      # aiur's list lags the provider by design, so an unknown model is more
      # likely new than wrong. SessionLifecycle surfaces it to the Executor.
      assert CodingAgent.resolve_model("codex", "gpt-9.9-nova") == "gpt-9.9-nova"
      assert CodingAgent.resolve_model("codex", nil) == nil
    end

    test "a bare model:<backend> override resolves to that backend's registered default model" do
      # A bare `model:deepseek` selects the backend without pinning a model; the
      # routing table is codex/claude shaped and does not name it. The session
      # must fall back to the backend's `openai_compat.default_model` rather
      # than starting with `nil` (which surfaces as `unsupported_model`).
      assert CodingAgent.resolve_model("deepseek", nil) == "deepseek-v4-flash"
      assert CodingAgent.resolve_model("kimi", nil) == "kimi-k2.7-code"
    end

    test "known_model?/2 covers both aliases and pinned versions, and nothing else" do
      assert CodingAgent.known_model?("codex", "sol")
      assert CodingAgent.known_model?("codex", "gpt-5.4")
      assert CodingAgent.known_model?("claude", "opus")
      refute CodingAgent.known_model?("codex", "gpt-9.9-nova")
      refute CodingAgent.known_model?("codex", nil)
    end

    test "override_labels/1 seeds the backend then its bare family tags, never a version" do
      labels = CodingAgent.override_labels(["codex"])

      assert hd(labels) == "model:codex"
      assert "model:sol" in labels
      refute Enum.any?(labels, &(&1 =~ ~r/\d/))
    end

    test "override_labels/2 seeds the families a CLI reported, even ones the registry lacks" do
      labels =
        CodingAgent.override_labels(["claude", "codex"], fn
          "claude" -> ["opus", "sonnet", "default", "sonnet[1m]", "opus-5-5"]
          "codex" -> ["gpt-5.7-astra", "gpt-5.6-sol", "gpt-5.5-codex", "gpt-5.5-high"]
        end)

      assert Enum.sort(labels) ==
               Enum.sort(["model:claude", "model:codex", "model:opus", "model:sonnet", "model:astra", "model:sol"])
    end
  end
end
