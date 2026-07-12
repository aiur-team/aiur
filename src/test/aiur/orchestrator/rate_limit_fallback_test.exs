defmodule Aiur.Orchestrator.RateLimitFallbackTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.RateLimitFallback

  # Matches the test fixture's tracker.github.label_prefix ("agent").
  @marker_label "agent:rate-limit-fallback"

  describe "decide/3" do
    test "engages when a codex-backed entry pauses on usage_limit_exhausted" do
      entry = %{control: %{status: :paused}, paused_reason: :usage_limit_exhausted}
      # Forces backend_for/1 to resolve "codex" regardless of the ambient
      # agent.kind default (Config.inferred_agent_kind/1 falls back to
      # "claude" for a config with no explicit agent.kind / codex / claude
      # section, which the test fixture is).
      issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:codex"]}

      assert RateLimitFallback.decide(entry, issue, fallback_backend: "claude") == :engage
    end

    test "does nothing when the fallback backend is disabled" do
      entry = %{control: %{status: :paused}, paused_reason: :usage_limit_exhausted}
      issue = %Issue{id: "1", identifier: "repo#1", labels: []}

      assert RateLimitFallback.decide(entry, issue, fallback_backend: nil) == :noop
    end

    test "does nothing when the issue already carries an unrelated model: override" do
      entry = %{control: %{status: :paused}, paused_reason: :usage_limit_exhausted}
      issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:claude"]}

      assert RateLimitFallback.decide(entry, issue, fallback_backend: "claude") == :noop
    end

    test "does nothing when the entry is not currently paused" do
      entry = %{control: %{status: :working}, paused_reason: :usage_limit_exhausted}
      issue = %Issue{id: "1", identifier: "repo#1", labels: []}

      assert RateLimitFallback.decide(entry, issue, fallback_backend: "claude") == :noop
    end

    test "does nothing for a pause reason other than usage_limit_exhausted" do
      entry = %{control: %{status: :paused}, paused_reason: :operator_pause}
      issue = %Issue{id: "1", identifier: "repo#1", labels: []}

      assert RateLimitFallback.decide(entry, issue, fallback_backend: "claude") == :noop
    end

    test "reverts an engaged fallback once codex is available again" do
      entry = %{control: %{status: :paused}, paused_reason: :usage_limit_exhausted}
      issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:claude", @marker_label]}

      assert RateLimitFallback.decide(entry, issue,
               fallback_backend: "claude",
               state: %{"backends" => %{"codex" => %{}}}
             ) == :revert
    end

    test "stays engaged while codex is still limited" do
      entry = %{control: %{status: :paused}, paused_reason: :usage_limit_exhausted}
      issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:claude", @marker_label]}

      future_reset_at = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()

      assert RateLimitFallback.decide(entry, issue,
               fallback_backend: "claude",
               state: %{"backends" => %{"codex" => %{"limited" => true, "reset_at" => future_reset_at}}}
             ) == :noop
    end

    test "leaves an operator's own model:claude label untouched even once codex recovers" do
      entry = %{control: %{status: :working}, paused_reason: nil}
      issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:claude"]}

      assert RateLimitFallback.decide(entry, issue,
               fallback_backend: "claude",
               state: %{"backends" => %{"codex" => %{}}}
             ) == :noop
    end
  end

  describe "fallback_engaged?/1" do
    test "true only when the durable marker label is present" do
      refute RateLimitFallback.fallback_engaged?(%Issue{labels: ["model:claude"]})
      assert RateLimitFallback.fallback_engaged?(%Issue{labels: ["model:claude", @marker_label]})
    end
  end
end
