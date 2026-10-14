Code.require_file("fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.RateLimitFallback.DecideTest do
  use ExUnit.Case, async: true
  import Aiur.RateLimitFallbackFixture, only: [fallback_entry: 1, recovered_state: 0]

  alias Aiur.Issue
  alias Aiur.Orchestrator.RateLimitFallback

  @marker_label "agent:rate-limit-fallback"

  describe "decide/3" do
    test "selects a second Claude account after a resumable session hits its account limit" do
      entry = %{
        control: %{status: :paused},
        paused_reason: :usage_limit_exhausted,
        usage_limit_session: %{backend: "claude-repl", account_name: "default", session_id: "session-1", cwd: "/repo"}
      }

      issue = %Issue{id: "1", identifier: "repo#1", labels: []}
      config = %{accounts: %{"claude" => ["default", "work"]}, account_selection: "priority"}

      options = [
        account_config: config,
        account_list_fun: fn _ -> [%{name: "default"}, %{name: "work"}] end,
        account_usage_fetcher: fn "work" -> %{"seven_day" => 35, "five_hour" => 40} end
      ]

      assert RateLimitFallback.decide(entry, issue, options) == :handoff
    end

    test "future regression: headless Claude stays on the reset wait because its app-server cannot resume moved transcripts" do
      entry = %{
        control: %{status: :paused},
        paused_reason: :usage_limit_exhausted,
        # Aiur.CodingAgent.Providers.Claude.headless/0 declares resumable: false:
        # its app-server keeps thread state in memory and thread/start cannot
        # seed a prior session id.
        usage_limit_session: %{backend: "claude", account_name: "default", session_id: "session-1", cwd: "/repo"}
      }

      issue = %Issue{id: "1", identifier: "repo#1", labels: []}
      config = %{accounts: %{"claude" => ["default", "work"]}, account_selection: "priority"}
      test_pid = self()

      options = [
        account_config: config,
        account_list_fun: fn _ -> [%{name: "default"}, %{name: "work"}] end,
        account_usage_fetcher: fn name ->
          send(test_pid, {:account_usage_fetched, name})
          %{"seven_day" => 35, "five_hour" => 40}
        end
      ]

      assert RateLimitFallback.decide(entry, issue, options) == :noop
      refute_received {:account_usage_fetched, _name}
    end

    # This guards the existing reset-wait behavior against future handoff changes.
    test "future regression: keeps the reset wait when every other Claude account is at its limit" do
      entry = %{
        control: %{status: :paused},
        paused_reason: :usage_limit_exhausted,
        usage_limit_session: %{backend: "claude-repl", account_name: "default", session_id: "session-1", cwd: "/repo"}
      }

      issue = %Issue{id: "1", identifier: "repo#1", labels: []}
      config = %{accounts: %{"claude" => ["default", "work"]}, account_selection: "priority"}

      options = [
        account_config: config,
        account_list_fun: fn _ -> [%{name: "default"}, %{name: "work"}] end,
        account_usage_fetcher: fn "work" -> %{"seven_day" => 100, "five_hour" => 100} end
      ]

      assert RateLimitFallback.decide(entry, issue, options) == :noop
    end

    test "engages when a codex-backed entry pauses on usage_limit_exhausted" do
      entry = %{control: %{status: :paused}, paused_reason: :usage_limit_exhausted}
      issue = %Issue{id: "1", identifier: "repo#1", labels: []}

      assert RateLimitFallback.decide(entry, issue, primary_backend: "codex", fallback_backend: "claude", current_backend: "codex") == :engage
    end

    test "does not engage when the issue already carries an explicit override, even if it resolves to codex" do
      # override_backend/1 resolves the FIRST model:<backend> label in list
      # order, so an operator-authored model:codex label appended alongside
      # our own model:claude would make engage a silent no-op (or make
      # revert strip the wrong label). Refusing to engage when any explicit
      # override already exists avoids the ambiguity entirely.
      entry = %{control: %{status: :paused}, paused_reason: :usage_limit_exhausted}
      issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:codex"]}

      assert RateLimitFallback.decide(entry, issue, primary_backend: "codex", fallback_backend: "claude", current_backend: "codex") == :noop
    end

    test "does nothing when the fallback backend is disabled" do
      entry = %{control: %{status: :paused}, paused_reason: :usage_limit_exhausted}
      issue = %Issue{id: "1", identifier: "repo#1", labels: []}

      assert RateLimitFallback.decide(entry, issue, primary_backend: "codex", fallback_backend: nil) == :noop
    end

    test "does nothing when the issue already carries an unrelated model: override" do
      entry = %{control: %{status: :paused}, paused_reason: :usage_limit_exhausted}
      issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:claude"]}

      assert RateLimitFallback.decide(entry, issue, primary_backend: "codex", fallback_backend: "claude") == :noop
    end

    test "does nothing when the entry is not currently paused" do
      entry = %{control: %{status: :working}, paused_reason: :usage_limit_exhausted}
      issue = %Issue{id: "1", identifier: "repo#1", labels: []}

      assert RateLimitFallback.decide(entry, issue, primary_backend: "codex", fallback_backend: "claude") == :noop
    end

    test "does not fetch account usage for a session that is not paused" do
      entry = %{
        control: %{status: :working},
        paused_reason: :usage_limit_exhausted,
        usage_limit_session: %{backend: "claude-repl", account_name: "default", session_id: "session-1", cwd: "/repo"}
      }

      issue = %Issue{id: "1", identifier: "repo#1", labels: []}
      test_pid = self()
      config = %{accounts: %{"claude" => ["default", "work"]}, account_selection: "priority"}

      options = [
        account_config: config,
        account_list_fun: fn _ -> [%{name: "default"}, %{name: "work"}] end,
        account_usage_fetcher: fn name ->
          send(test_pid, {:account_usage_fetched, name})
          nil
        end
      ]

      assert RateLimitFallback.decide(entry, issue, options) == :noop
      refute_received {:account_usage_fetched, _name}
    end

    test "does nothing for a pause reason other than usage_limit_exhausted" do
      entry = %{control: %{status: :paused}, paused_reason: :operator_pause}
      issue = %Issue{id: "1", identifier: "repo#1", labels: []}

      assert RateLimitFallback.decide(entry, issue, primary_backend: "codex", fallback_backend: "claude") == :noop
    end

    test "reverts an engaged fallback once codex is available again" do
      entry = fallback_entry(%{control: %{status: :paused}, paused_reason: :usage_limit_exhausted})
      issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:claude", @marker_label]}

      assert RateLimitFallback.decide(entry, issue,
               primary_backend: "codex",
               fallback_backend: "claude",
               state: recovered_state()
             ) == :revert
    end

    test "does not revert while paused for a reason other than usage_limit_exhausted" do
      # An operator's own pause (or any other automatic pause) must not be
      # silently torn down and redispatched just because codex recovered.
      entry = %{control: %{status: :paused}, paused_reason: :operator_pause}
      issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:claude", @marker_label]}

      assert RateLimitFallback.decide(entry, issue,
               primary_backend: "codex",
               fallback_backend: "claude",
               state: recovered_state()
             ) == :noop
    end

    test "stays engaged while codex is still limited" do
      entry = %{control: %{status: :paused}, paused_reason: :usage_limit_exhausted}
      issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:claude", @marker_label]}

      future_reset_at = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()

      assert RateLimitFallback.decide(entry, issue,
               primary_backend: "codex",
               fallback_backend: "claude",
               state: %{"backends" => %{"codex" => %{"limited" => true, "reset_at" => future_reset_at}}}
             ) == :noop
    end

    test "retries engagement after a marker-only partial write while codex is still limited" do
      entry = %{control: %{status: :paused}, paused_reason: :usage_limit_exhausted}
      issue = %Issue{id: "1", identifier: "repo#1", labels: [@marker_label]}
      future_reset_at = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()

      assert RateLimitFallback.decide(entry, issue,
               primary_backend: "codex",
               fallback_backend: "claude",
               current_backend: "codex",
               state: %{"backends" => %{"codex" => %{"limited" => true, "reset_at" => future_reset_at}}}
             ) == :engage
    end

    test "leaves an operator's own model:claude label untouched even once codex recovers" do
      entry = %{control: %{status: :working}, paused_reason: nil}
      issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:claude"]}

      assert RateLimitFallback.decide(entry, issue,
               primary_backend: "codex",
               fallback_backend: "claude",
               state: recovered_state()
             ) == :noop
    end

    test "does not revert on the one-hour unknown-reset expiry alone" do
      old = DateTime.add(DateTime.utc_now(), -3_601, :second) |> DateTime.to_iso8601()
      entry = fallback_entry(%{control: %{status: :working}, paused_reason: nil})
      issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:claude", @marker_label]}

      assert RateLimitFallback.decide(entry, issue,
               primary_backend: "codex",
               fallback_backend: "claude",
               state: %{
                 "backends" => %{
                   "codex" => %{"limited" => true, "observed_at" => old}
                 }
               }
             ) == :noop
    end

    test "waits for minimum fallback dwell before requesting recovery" do
      now = DateTime.utc_now()
      entry = fallback_entry(%{control: %{status: :working}, started_at: now})
      issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:claude", @marker_label]}

      assert RateLimitFallback.decide(entry, issue,
               primary_backend: "codex",
               fallback_backend: "claude",
               state: recovered_state(),
               now: now,
               minimum_dwell_seconds: 60
             ) == :noop
    end

    test "requests a cooperative pause before reverting a working fallback" do
      entry = fallback_entry(%{control: %{status: :working}, paused_reason: nil})
      issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:claude", @marker_label]}

      assert RateLimitFallback.decide(entry, issue,
               primary_backend: "codex",
               fallback_backend: "claude",
               state: recovered_state(),
               minimum_dwell_seconds: 0
             ) == :prepare_revert
    end
  end

  test "engages any configured registered backend pair, not just codex -> claude" do
    # The pair is registry-driven: an already-running agent on the configured
    # primary reroutes to the configured fallback, whatever they are.
    entry = %{control: %{status: :paused}, paused_reason: :usage_limit_exhausted}
    issue = %Issue{id: "1", identifier: "repo#1", labels: []}

    assert RateLimitFallback.decide(entry, issue,
             primary_backend: "claude",
             fallback_backend: "codex",
             current_backend: "claude"
           ) == :engage
  end

  test "does not engage when the running backend is not the configured primary" do
    entry = %{control: %{status: :paused}, paused_reason: :usage_limit_exhausted}
    issue = %Issue{id: "1", identifier: "repo#1", labels: []}

    assert RateLimitFallback.decide(entry, issue,
             primary_backend: "claude",
             fallback_backend: "codex",
             current_backend: "codex"
           ) == :noop
  end

  describe "fallback_engaged?/1" do
    test "true only when the durable marker label is present" do
      refute RateLimitFallback.fallback_engaged?(%Issue{labels: ["model:claude"]})
      assert RateLimitFallback.fallback_engaged?(%Issue{labels: ["model:claude", @marker_label]})
      assert RateLimitFallback.fallback_engaged?(%Issue{labels: [@marker_label]}, " Agent:Rate-Limit-Fallback ")
    end
  end
end
