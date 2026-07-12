defmodule Aiur.Orchestrator.RateLimitFallbackTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.{RateLimitFallback, State}

  # Matches the test fixture's tracker.github.label_prefix ("agent").
  @marker_label "agent:rate-limit-fallback"

  describe "decide/3" do
    test "engages when a codex-backed entry pauses on usage_limit_exhausted" do
      entry = %{control: %{status: :paused}, paused_reason: :usage_limit_exhausted}
      issue = %Issue{id: "1", identifier: "repo#1", labels: []}

      assert RateLimitFallback.decide(entry, issue, fallback_backend: "claude", current_backend: "codex") == :engage
    end

    test "does not engage when the issue already carries an explicit override, even if it resolves to codex" do
      # override_backend/1 resolves the FIRST model:<backend> label in list
      # order, so an operator-authored model:codex label appended alongside
      # our own model:claude would make engage a silent no-op (or make
      # revert strip the wrong label). Refusing to engage when any explicit
      # override already exists avoids the ambiguity entirely.
      entry = %{control: %{status: :paused}, paused_reason: :usage_limit_exhausted}
      issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:codex"]}

      assert RateLimitFallback.decide(entry, issue, fallback_backend: "claude", current_backend: "codex") == :noop
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

    test "does not revert while paused for a reason other than usage_limit_exhausted" do
      # An operator's own pause (or any other automatic pause) must not be
      # silently torn down and redispatched just because codex recovered.
      entry = %{control: %{status: :paused}, paused_reason: :operator_pause}
      issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:claude", @marker_label]}

      assert RateLimitFallback.decide(entry, issue,
               fallback_backend: "claude",
               state: %{"backends" => %{"codex" => %{}}}
             ) == :noop
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

    test "retries engagement after a marker-only partial write while codex is still limited" do
      entry = %{control: %{status: :paused}, paused_reason: :usage_limit_exhausted}
      issue = %Issue{id: "1", identifier: "repo#1", labels: [@marker_label]}
      future_reset_at = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()

      assert RateLimitFallback.decide(entry, issue,
               fallback_backend: "claude",
               current_backend: "codex",
               state: %{"backends" => %{"codex" => %{"limited" => true, "reset_at" => future_reset_at}}}
             ) == :engage
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
      assert RateLimitFallback.fallback_engaged?(%Issue{labels: [@marker_label]}, " Agent:Rate-Limit-Fallback ")
    end
  end

  describe "reconcile/2" do
    test "engages the fallback, relabels the issue, and preserves worker affinity on redispatch" do
      state = fallback_state([], "codex")
      test_pid = self()

      result =
        RateLimitFallback.reconcile(
          state,
          reconcile_opts(
            add_label_fun: fn identifier, label ->
              send(test_pid, {:label_op, {:add, identifier, label}})
              :ok
            end,
            remove_label_fun: fn identifier, label ->
              send(test_pid, {:label_op, {:remove, identifier, label}})
              :ok
            end,
            teardown_fun: fn current_state, running_entry, reason ->
              send(test_pid, {:teardown, running_entry.identifier, reason})
              current_state
            end,
            dispatch_fun: fn current_state, issue, attempt, worker_host ->
              send(test_pid, {:dispatch, issue, attempt, worker_host})
              %{current_state | completed: MapSet.put(current_state.completed, issue.id)}
            end
          )
        )

      assert result.completed == MapSet.new(["1"])

      assert_label_ops([
        {:add, "repo#1", @marker_label},
        {:add, "repo#1", "model:claude"}
      ])

      assert_received {:teardown, "repo#1", :rate_limit_fallback}
      assert_received {:dispatch, %Issue{labels: ["model:claude", @marker_label], selected_backend: nil}, nil, "worker-2"}
      refute_received {:label_op, _}
    end

    test "reverts the fallback labels and redispatches to the original worker" do
      state = fallback_state(["model:claude", @marker_label], "claude")
      test_pid = self()

      result =
        RateLimitFallback.reconcile(
          state,
          reconcile_opts(
            fallback_backend: "config-changed-after-engage",
            add_label_fun: fn identifier, label ->
              send(test_pid, {:label_op, {:add, identifier, label}})
              :ok
            end,
            remove_label_fun: fn identifier, label ->
              send(test_pid, {:label_op, {:remove, identifier, label}})
              :ok
            end,
            teardown_fun: fn current_state, running_entry, reason ->
              send(test_pid, {:teardown, running_entry.identifier, reason})
              current_state
            end,
            dispatch_fun: fn current_state, issue, attempt, worker_host ->
              send(test_pid, {:dispatch, issue, attempt, worker_host})
              %{current_state | completed: MapSet.put(current_state.completed, issue.id)}
            end
          )
        )

      assert result.completed == MapSet.new(["1"])

      assert_label_ops([
        {:remove, "repo#1", "model:claude"},
        {:remove, "repo#1", @marker_label}
      ])

      assert_received {:teardown, "repo#1", :rate_limit_fallback}
      assert_received {:dispatch, %Issue{labels: [], selected_backend: nil}, nil, "worker-2"}
      refute_received {:label_op, _}
    end

    test "removes the inert marker when adding the routing label fails" do
      state = fallback_state([])
      test_pid = self()

      assert RateLimitFallback.reconcile(
               state,
               reconcile_opts(
                 add_label_fun: fn identifier, label ->
                   send(test_pid, {:label_op, {:add, identifier, label}})

                   if label == "model:claude",
                     do: {:error, :model_write_failed},
                     else: :ok
                 end,
                 remove_label_fun: fn identifier, label ->
                   send(test_pid, {:label_op, {:remove, identifier, label}})
                   :ok
                 end,
                 teardown_fun: fn _, _, _ -> flunk("must not tear down after a label-write failure") end,
                 dispatch_fun: fn _, _, _, _ -> flunk("must not dispatch after a label-write failure") end
               )
             ) == state

      assert_label_ops([
        {:add, "repo#1", @marker_label},
        {:add, "repo#1", "model:claude"},
        {:remove, "repo#1", @marker_label}
      ])
    end

    test "restores routing when removing the marker fails" do
      state = fallback_state(["model:claude", @marker_label])
      test_pid = self()

      assert RateLimitFallback.reconcile(
               state,
               reconcile_opts(
                 add_label_fun: fn identifier, label ->
                   send(test_pid, {:label_op, {:add, identifier, label}})
                   :ok
                 end,
                 remove_label_fun: fn identifier, label ->
                   send(test_pid, {:label_op, {:remove, identifier, label}})

                   if label == @marker_label,
                     do: {:error, :marker_remove_failed},
                     else: :ok
                 end,
                 teardown_fun: fn _, _, _ -> flunk("must not tear down after a label-write failure") end,
                 dispatch_fun: fn _, _, _, _ -> flunk("must not dispatch after a label-write failure") end
               )
             ) == state

      assert_label_ops([
        {:remove, "repo#1", "model:claude"},
        {:remove, "repo#1", @marker_label},
        {:add, "repo#1", "model:claude"}
      ])
    end

    test "ignores running entries without an issue" do
      state = %State{running: %{"1" => %{control: %{status: :paused}}}}

      assert RateLimitFallback.reconcile(state, reconcile_opts()) == state
    end
  end

  defp fallback_state(labels, selected_backend \\ nil) do
    issue = %Issue{id: "1", identifier: "repo#1", labels: labels, selected_backend: selected_backend}

    entry = %{
      identifier: issue.identifier,
      issue: issue,
      worker_host: "worker-2",
      control: %{status: :paused},
      paused_reason: :usage_limit_exhausted
    }

    %State{running: %{issue.id => entry}}
  end

  defp reconcile_opts(overrides \\ []) do
    Keyword.merge(
      [
        fallback_backend: "claude",
        marker_label: @marker_label,
        current_backend: "codex",
        state: %{"backends" => %{"codex" => %{}}}
      ],
      overrides
    )
  end

  defp assert_label_ops(expected) do
    actual =
      Enum.map(expected, fn _operation ->
        assert_receive {:label_op, operation}
        operation
      end)

    assert actual == expected
  end
end
