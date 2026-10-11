defmodule Aiur.CodingAgent.RoutingTest do
  use ExUnit.Case, async: true

  alias Aiur.CodingAgent
  alias Aiur.Issue

  defp issue(labels), do: %Issue{labels: labels}

  describe "select_for_dispatch/2" do
    test "uses the first configured, available fallback from an ordered list" do
      assert {:ok, %Issue{selected_backend: "claude"}} =
               CodingAgent.select_for_dispatch(issue([]),
                 backends: ["unconfigured", "claude", "codex"],
                 configured_backends: ["claude"]
               )
    end

    test "keeps an explicit backend selection unchanged" do
      explicit = %Issue{labels: ["model:codex"]}

      assert {:ok, ^explicit} =
               CodingAgent.select_for_dispatch(explicit,
                 backends: ["claude"],
                 configured_backends: ["claude"]
               )
    end

    test "reports all configured candidates when none is available" do
      state = %{
        "backends" => %{"claude" => %{"limited" => true, "reset_at" => "2999-01-01T00:00:00Z"}}
      }

      assert {:all_limited, ["claude"]} =
               CodingAgent.select_for_dispatch(issue([]),
                 backends: ["claude", "codex"],
                 configured_backends: ["claude"],
                 state: state
               )
    end

    # The 2026-09-26 khala incident. Every ticket carried a `complexity:` label
    # and `agent.routing` named claude at every level, so a routed backend
    # short-circuited with no availability check and the fleet kept dispatching
    # into its own exhausted Claude account.
    @limited %{"backends" => %{"claude" => %{"limited" => true, "reset_at" => "2999-01-01T00:00:00Z"}}}

    test "an unlabelled ticket waits when its default backend is usage-limited" do
      assert {:all_limited, ["claude"]} =
               CodingAgent.select_for_dispatch(issue([]),
                 backends: [],
                 default_backend: "claude",
                 state: @limited,
                 now: ~U[2026-09-26 02:30:00Z]
               )
    end

    test "a usage-limited routed backend parks the claim instead of dispatching into the limit" do
      assert {:all_limited, ["claude"]} =
               CodingAgent.select_for_dispatch(issue(["complexity:3"]),
                 routing_backend: "claude",
                 state: @limited,
                 now: ~U[2026-09-26 02:30:00Z]
               )
    end

    test "an available routed backend dispatches unchanged" do
      unchanged = issue(["complexity:3"])

      assert {:ok, ^unchanged} =
               CodingAgent.select_for_dispatch(unchanged,
                 routing_backend: "codex",
                 state: @limited,
                 now: ~U[2026-09-26 02:30:00Z]
               )
    end

    test "an operator's model: override still dispatches onto a limited backend" do
      # A pin is intent. Only a routed default is second-guessed.
      pinned = issue(["model:claude", "complexity:3"])

      assert {:ok, ^pinned} =
               CodingAgent.select_for_dispatch(pinned,
                 routing_backend: "claude",
                 state: @limited,
                 now: ~U[2026-09-26 02:30:00Z]
               )
    end

    test "selects codex after claude is marked limited" do
      state = %{
        "backends" => %{"claude" => %{"limited" => true, "reset_at" => "2999-01-01T00:00:00Z"}}
      }

      assert {:ok, %Issue{selected_backend: "codex"}} =
               CodingAgent.select_for_dispatch(issue([]),
                 backends: ["claude", "codex"],
                 configured_backends: ["claude", "codex"],
                 state: state
               )
    end
  end

  describe "override_backend/1 (model: tag selects backend)" do
    test "bare model:<backend> selects that backend" do
      assert CodingAgent.override_backend(issue(["model:claude"])) == "claude"
      assert CodingAgent.override_backend(issue(["model:codex"])) == "codex"
    end

    test "model:<backend>-<variant> still selects the backend" do
      assert CodingAgent.override_backend(issue(["model:claude-opus-4-8"])) == "claude"
    end

    test "a hyphenated backend is resolved whole, not split into backend+variant" do
      # `claude-repl` must win over the shorter `claude` so its trailing
      # `repl` segment is not mistaken for a model variant.
      assert CodingAgent.override_backend(issue(["model:claude-repl"])) == "claude-repl"
      assert CodingAgent.model_for(issue(["model:claude-repl"])) == nil
    end

    test "a hyphenated backend still pins a trailing variant" do
      assert CodingAgent.override_backend(issue(["model:claude-repl-opus-4-8"])) == "claude-repl"
      assert CodingAgent.model_for(issue(["model:claude-repl-opus-4-8"])) == "opus-4-8"
    end

    test "unknown backend in a model: tag is ignored" do
      assert CodingAgent.override_backend(issue(["model:bogus"])) == nil
      assert CodingAgent.override_backend(issue(["model:bogus-x"])) == nil
    end

    test "no model: tag yields nil" do
      assert CodingAgent.override_backend(issue(["complexity:5", "agent:todo"])) == nil
    end
  end

  describe "model:remote is a remote flag, not a backend selector" do
    test "the bare alias selects no backend and pins no model" do
      assert CodingAgent.override_backend(issue(["model:remote"])) == nil
      assert CodingAgent.model_for(issue(["model:remote"])) == nil
    end

    test "a companion model tag picks backend+model; the alias only forces RC" do
      issue = issue(["model:claude-haiku", "model:remote"])
      assert CodingAgent.backend_for(issue) == "claude"
      assert CodingAgent.model_for(issue) == "haiku"
      assert CodingAgent.remote_control_forced?(issue)
    end

    test "the alias is skipped regardless of label order" do
      reordered = issue(["model:remote", "model:claude-haiku"])
      assert CodingAgent.backend_for(reordered) == "claude"
      assert CodingAgent.model_for(reordered) == "haiku"
    end

    test "remote_control_forced? is true only when the alias label is present" do
      assert CodingAgent.remote_control_forced?(issue(["model:remote"]))
      refute CodingAgent.remote_control_forced?(issue(["model:claude-repl"]))
      refute CodingAgent.remote_control_forced?(issue(["model:claude"]))
      refute CodingAgent.remote_control_forced?(issue(["complexity:5"]))
    end

    test "an alias-variant label is flag-only (no backend/model) but still forces RC" do
      assert CodingAgent.override_backend(issue(["model:remote-sonnet"])) == nil
      assert CodingAgent.model_for(issue(["model:remote-sonnet"])) == nil
      assert CodingAgent.remote_control_forced?(issue(["model:remote-sonnet"]))
      assert CodingAgent.remote_control_forced?(issue(["model:remote-opus-4-8"]))
      refute CodingAgent.remote_control_forced?(issue(["model:claude-sonnet"]))
    end

    test "the alias label is auto-seeded" do
      assert "model:remote" in CodingAgent.override_labels()
    end

    test "routing_remote? is false with no complexity label (global config untouched)" do
      refute CodingAgent.routing_remote?(issue(["agent:todo"]))
    end
  end

  describe "backend_for/1 precedence (override beats routing/default)" do
    test "a model: override wins over a complexity: label that would route elsewhere" do
      assert CodingAgent.backend_for(issue(["model:claude", "complexity:5"])) == "claude"
      assert CodingAgent.backend_for(issue(["model:codex", "complexity:5"])) == "codex"
    end

    test "first matching model: label wins when several are present" do
      assert CodingAgent.override_backend(issue(["model:claude", "model:codex"])) == "claude"
      assert CodingAgent.override_backend(issue(["model:codex", "model:claude"])) == "codex"
    end
  end

  describe "override silent-drop boundaries (intentional fallthrough)" do
    test "a disallowed variant charset drops the whole override" do
      assert CodingAgent.override_backend(issue(["model:claude-opus_4"])) == nil
      assert CodingAgent.model_for(issue(["model:claude-opus_4"])) == nil
    end

    test "a capitalized backend is not recognized" do
      assert CodingAgent.override_backend(issue(["model:Claude"])) == nil
    end
  end

  describe "model_for/1 (3-layer model: tag)" do
    test "broadest model:<backend> pins no model (backend default)" do
      assert CodingAgent.model_for(issue(["model:claude"])) == nil
      assert CodingAgent.model_for(issue(["model:codex"])) == nil
    end

    test "family layer pins the family string" do
      assert CodingAgent.model_for(issue(["model:claude-opus"])) == "opus"
      assert CodingAgent.model_for(issue(["model:claude-sonnet"])) == "sonnet"
      assert CodingAgent.model_for(issue(["model:claude-haiku"])) == "haiku"
    end

    test "specific layer pins the exact version string" do
      assert CodingAgent.model_for(issue(["model:claude-opus-4-8"])) == "opus-4-8"
      assert CodingAgent.model_for(issue(["model:codex-gpt-5.6-sol"])) == "gpt-5.6-sol"
      assert CodingAgent.model_for(issue(["model:codex-gpt-5.6-terra"])) == "gpt-5.6-terra"
      assert CodingAgent.model_for(issue(["model:codex-gpt-5.6-luna"])) == "gpt-5.6-luna"
      assert CodingAgent.model_for(issue(["model:codex-gpt-5.5"])) == "gpt-5.5"
      assert CodingAgent.model_for(issue(["model:codex-gpt-5.4-mini"])) == "gpt-5.4-mini"
    end

    test "no model: tag pins nothing" do
      assert CodingAgent.model_for(issue(["complexity:4"])) == nil
    end
  end

  describe "effort_for/1 (model:<effort> override label)" do
    test "a model:<effort> label sets effort with no routing configured" do
      assert CodingAgent.effort_for(issue(["model:low"])) == "low"
      assert CodingAgent.effort_for(issue(["model:medium"])) == "medium"
      assert CodingAgent.effort_for(issue(["model:high"])) == "high"
      assert CodingAgent.effort_for(issue(["model:xhigh"])) == "xhigh"
      assert CodingAgent.effort_for(issue(["model:max"])) == "max"
    end

    test "the first well-formed effort label wins when several are present" do
      assert CodingAgent.effort_for(issue(["model:low", "model:max"])) == "low"
    end

    test "an unsupported effort spec is ignored (no effort, not a backend)" do
      assert CodingAgent.effort_for(issue(["model:ultra"])) == nil
      assert CodingAgent.override_backend(issue(["model:ultra"])) == nil
    end

    test "an effort label never selects a backend or pins a model" do
      assert CodingAgent.override_backend(issue(["model:xhigh"])) == nil
      assert CodingAgent.model_for(issue(["model:xhigh"])) == nil
    end
  end

  describe "complexity_level/1" do
    test "highest well-formed complexity wins" do
      assert CodingAgent.complexity_level(issue(["complexity:2", "complexity:5"])) == 5
    end

    test "absent or malformed complexity yields nil" do
      assert CodingAgent.complexity_level(issue(["agent:todo"])) == nil
      assert CodingAgent.complexity_level(issue(["complexity:high"])) == nil
    end
  end
end
