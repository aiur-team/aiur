defmodule Aiur.GitHub.LabelsTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.Labels

  describe "label_set/2" do
    test "claude+codex covers state, both model families, and complexity" do
      labels = Labels.label_set("aiur", ["claude", "codex"])

      assert "aiur:todo" in labels
      assert "aiur:ci-wait" in labels
      assert "aiur:human-review" in labels
      assert "model:claude" in labels
      assert "model:claude-opus" in labels
      assert "model:codex" in labels
      assert "model:codex-gpt-5.6-sol" in labels
      assert "model:codex-gpt-5.6-terra" in labels
      assert "model:codex-gpt-5.6-luna" in labels
      assert "model:codex-gpt-5.5" in labels
      assert "complexity:1" in labels
      assert "complexity:5" in labels
    end

    test "includes marker labels, kept out of the dispatch states" do
      labels = Labels.label_set("agent", ["codex"])

      assert "agent:watch" in labels
      assert "agent:paused" in labels
      assert "agent:parked" in labels
      assert "agent:rate-limit-fallback" in labels
      refute "agent:watch" in Labels.state_labels("agent")
      refute "agent:paused" in Labels.state_labels("agent")
      refute "agent:parked" in Labels.state_labels("agent")
      refute "agent:rate-limit-fallback" in Labels.state_labels("agent")
      assert Labels.marker_suffix?("rate-limit-fallback")
    end

    test "parked is a marker, not a dispatch state" do
      assert Labels.parked_labels("agent") == ["agent:parked"]
      # marker_suffix?/1 takes the bare suffix, not a full `prefix:suffix`
      # label — the full form must not read as a marker suffix (see #1971).
      assert Labels.marker_suffix?("parked")
      refute Labels.marker_suffix?("agent:parked")
      refute "agent:parked" in Labels.state_labels("agent")
    end

    test "fallback labels use the configured fallback pair" do
      labels = Labels.label_set("aiur", ["claude"])

      assert "model:claude" in labels
      refute "model:codex" in labels
    end

    test "fallback labels accept an explicitly configured registered pair" do
      labels = Labels.required_rate_limit_fallback_labels("aiur", "claude", "codex")

      assert "aiur:rate-limit-fallback" in labels
      assert "model:codex" in labels
      refute "model:claude-repl" in labels
    end

    test "fallback labels do not seed unconfigured backend labels" do
      labels = Labels.label_set("aiur", ["claude"])

      assert "model:claude" in labels
      refute "model:claude-repl" in labels
    end

    test "the claude-repl backend seeds its own labels when chosen" do
      labels = Labels.label_set("aiur", ["claude-repl"])

      assert "model:claude-repl" in labels
      assert "model:claude-repl-opus-4-8" in labels
      assert "model:claude" in labels
    end

    test "state labels honor the configured prefix" do
      assert "team:todo" in Labels.state_labels("team")
      refute "aiur:todo" in Labels.state_labels("team")
    end

    test "claude backends seed the remote-control alias; codex-only does not" do
      assert "model:remote" in Labels.label_set("agent", ["claude"])
      refute "model:remote" in Labels.label_set("agent", ["codex"])
    end

    test "claude seeds bare haiku and the remote flag" do
      labels = Labels.label_set("agent", ["claude"])

      assert "model:claude-haiku" in labels
      assert "model:remote" in labels
      refute "model:claude-repl" in labels
    end

    test "codex seeds the cheaper model variants" do
      labels = Labels.label_set("agent", ["codex"])

      assert "model:codex-gpt-5.6-terra" in labels
      assert "model:codex-gpt-5.6-luna" in labels
      assert "model:codex-gpt-5.4" in labels
      assert "model:codex-gpt-5.5-mini" in labels
      assert "model:codex-gpt-5.4-mini" in labels
    end

    test "effort labels are seeded regardless of the chosen backend" do
      for backends <- [["codex"], ["claude"], ["claude-repl"]] do
        labels = Labels.label_set("agent", backends)
        assert "model:low" in labels
        assert "model:xhigh" in labels
        assert "model:max" in labels
      end
    end
  end

  describe "describe/1" do
    test "gives a short description for each label family" do
      assert Labels.describe("agent:todo") == "ready to be worked"
      assert Labels.describe("agent:ci-wait") == "awaiting CI before human review"
      assert Labels.describe("model:remote") == "Supports claude remote-control"
      assert Labels.describe("model:claude") =~ "route this issue to claude"
      assert Labels.describe("model:claude-haiku") =~ "route this issue to claude-haiku"
      assert Labels.describe("model:xhigh") == "run this issue at xhigh reasoning effort"
      assert Labels.describe("complexity:3") == "story-point complexity 3"
      assert Labels.describe("agent:watch") == "aiur watches this PR for comments"
      assert Labels.describe("agent:paused") == "suppress aiur work while preserving state"
      assert Labels.describe("agent:parked") == "operator-held: no dispatch, no comment-driven rework"
      assert Labels.describe("agent:rate-limit-fallback") == "tracks automatic usage-limit fallback"
    end
  end

  describe "ensure/5" do
    test "posts one create per label and succeeds when all are created" do
      parent = self()

      stub = fn %{method: :post, url: url, body: %{"name" => name}} ->
        send(parent, {:created, url, name})
        {:ok, %{status: 201, body: %{}}}
      end

      assert :ok =
               Labels.ensure("octo", "repo", "tok", ["complexity:1", "complexity:2"], request_fun: stub)

      assert_received {:created, "https://api.github.com/repos/octo/repo/labels", "complexity:1"}
      assert_received {:created, _, "complexity:2"}
    end

    test "an already-existing label (422) counts as success" do
      stub = fn _req ->
        {:ok, %{status: 422, body: %{"errors" => [%{"code" => "already_exists"}]}}}
      end

      assert :ok = Labels.ensure("octo", "repo", "tok", ["complexity:1"], request_fun: stub)
    end

    test "a 422 that is not already_exists surfaces as an error" do
      stub = fn _req ->
        {:ok, %{status: 422, body: %{"errors" => [%{"code" => "invalid"}]}}}
      end

      assert {:error, {:github_api_status, 422, "complexity:1"}} =
               Labels.ensure("octo", "repo", "tok", ["complexity:1"], request_fun: stub)
    end

    test "a non-422 failure stops and surfaces the status" do
      stub = fn _req -> {:ok, %{status: 403, body: %{}}} end

      assert {:error, {:github_api_status, 403, "complexity:1"}} =
               Labels.ensure("octo", "repo", "tok", ["complexity:1", "complexity:2"], request_fun: stub)
    end

    test "a transport error surfaces" do
      stub = fn _req -> {:error, :timeout} end

      assert {:error, {:github_api_request, :timeout}} =
               Labels.ensure("octo", "repo", "tok", ["complexity:1"], request_fun: stub)
    end
  end
end
