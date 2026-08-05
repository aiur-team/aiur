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
              record_started_dispatch(current_state, issue)
            end
          )
        )

      assert result.completed == MapSet.new(["1"])

      assert_label_ops([
        {:add, "repo#1", @marker_label},
        {:add, "repo#1", "model:claude"}
      ])

      assert_received {:teardown, "repo#1", :rate_limit_fallback}
      assert_received {:dispatch, %Issue{labels: ["model:claude", @marker_label], selected_backend: "claude"}, nil, "worker-2"}
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
              record_started_dispatch(current_state, issue)
            end
          )
        )

      assert result.completed == MapSet.new(["1"])

      assert_label_ops([
        {:remove, "repo#1", "model:claude"},
        {:remove, "repo#1", @marker_label}
      ])

      assert_received {:teardown, "repo#1", :rate_limit_fallback}
      assert_received {:dispatch, %Issue{labels: [], selected_backend: "codex"}, nil, "worker-2"}
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

    test "defers before label writes when redispatch cannot start" do
      state = fallback_state([])

      assert RateLimitFallback.reconcile(
               state,
               reconcile_opts(
                 dispatch_ready_fun: fn _state, _issue, _worker_host ->
                   {:error, :thrash_circuit_open}
                 end,
                 add_label_fun: fn _, _ -> flunk("must not write labels when dispatch is deferred") end,
                 teardown_fun: fn _, _, _ -> flunk("must not tear down when dispatch is deferred") end,
                 dispatch_fun: fn _, _, _, _ -> flunk("must not dispatch when readiness fails") end
               )
             ) == state
    end

    test "leaves a known-limited fallback untouched" do
      reset_at = DateTime.add(DateTime.utc_now(), 3_600, :second) |> DateTime.to_iso8601()
      state = fallback_state([])

      assert RateLimitFallback.reconcile(
               state,
               reconcile_opts(
                 state: %{
                   "backends" => %{
                     "codex" => %{"limited" => true, "reset_at" => reset_at},
                     "claude" => %{"limited" => true, "reset_at" => reset_at}
                   }
                 },
                 add_label_fun: fn _, _ -> flunk("must not write labels for a limited fallback") end,
                 teardown_fun: fn _, _, _ -> flunk("must not tear down for a limited fallback") end
               )
             ) == state
    end

    test "leaves the codex agent parked when the fallback executable is unavailable" do
      state = fallback_state([])

      assert RateLimitFallback.reconcile(
               state,
               reconcile_opts(
                 backend_ready_fun: fn "claude", _worker_host -> false end,
                 add_label_fun: fn _, _ -> flunk("must not label an unrunnable fallback") end,
                 teardown_fun: fn _, _, _ -> flunk("must not tear down for an unrunnable fallback") end
               )
             ) == state
    end

    test "leaves a remote codex agent parked because headless claude is local-only" do
      state = fallback_state([])

      opts =
        reconcile_opts(
          find_executable_fun: fn _executable -> "/usr/bin/aiur-claude" end,
          add_label_fun: fn _, _ -> flunk("must not label a fallback that cannot use the workspace") end,
          teardown_fun: fn _, _, _ -> flunk("must not tear down a remote codex agent") end
        )
        |> Keyword.delete(:backend_ready_fun)

      assert RateLimitFallback.reconcile(state, opts) == state
    end

    test "releases a torn-down entry and schedules retry when dispatch unexpectedly no-ops" do
      identity = %Aiur.TrackerIdentity{
        version: 1,
        status: :joinable,
        kind: :github,
        owner: "owner",
        repository: "repo",
        provider_id: "I_kwDORetry",
        identifier: "repo#1"
      }

      state =
        fallback_state([])
        |> update_in([Access.key(:running), "1", :issue], &%{&1 | tracker_identity: identity})

      test_pid = self()

      result =
        RateLimitFallback.reconcile(
          state,
          reconcile_opts(
            add_label_fun: fn _, _ -> :ok end,
            teardown_fun: fn current_state, _, _ -> current_state end,
            dispatch_fun: fn current_state, _, _, _ -> current_state end,
            schedule_retry_fun: fn current_state, issue_id, attempt, metadata ->
              send(test_pid, {:retry, issue_id, attempt, metadata})

              %{
                current_state
                | retry_attempts: Map.put(current_state.retry_attempts, issue_id, %{attempt: attempt})
              }
            end
          )
        )

      refute Map.has_key?(result.running, "1")
      assert Map.has_key?(result.retry_attempts, "1")
      assert_received {:retry, "1", _, %{worker_host: "worker-2", tracker_identity: ^identity}}

      assert RateLimitFallback.reconcile(
               result,
               reconcile_opts(
                 add_label_fun: fn _, _ -> flunk("a deferred retry must not flap labels") end,
                 remove_label_fun: fn _, _ -> flunk("a deferred retry must not flap labels") end
               )
             ) == result
    end

    test "requests a safe checkpoint and waits for worker pause before reverting" do
      state = fallback_state(["model:claude", @marker_label], "claude", :working)
      test_pid = self()

      result =
        RateLimitFallback.reconcile(
          state,
          reconcile_opts(
            pause_fun: fn _current_state, identifier ->
              send(test_pid, {:pause, identifier})
              {:ok, 7}
            end,
            add_label_fun: fn _, _ -> flunk("must not relabel a working fallback") end,
            remove_label_fun: fn _, _ -> flunk("must not relabel a working fallback") end,
            teardown_fun: fn _, _, _ -> flunk("must not tear down mid-turn") end,
            dispatch_fun: fn _, _, _, _ -> flunk("must not dispatch mid-turn") end
          )
        )

      assert_received {:pause, "repo#1"}
      assert get_in(result.running, ["1", :control, :status]) == :working
      assert get_in(result.running, ["1", :paused_reason]) == :rate_limit_fallback_recovery
      assert get_in(result.running, ["1", :rate_limit_fallback_revert_pending]) == true
    end

    test "cancels a pending recovery checkpoint when codex becomes limited again" do
      reset_at = DateTime.add(DateTime.utc_now(), 3_600, :second) |> DateTime.to_iso8601()
      state = fallback_state(["model:claude", @marker_label], "claude", :working)

      state =
        update_in(state.running["1"], fn entry ->
          entry
          |> Map.put(:rate_limit_fallback_revert_pending, true)
          |> Map.put(:paused_reason, :rate_limit_fallback_recovery)
        end)

      result =
        RateLimitFallback.reconcile(
          state,
          reconcile_opts(
            state: %{
              "backends" => %{
                "codex" => %{"limited" => true, "reset_at" => reset_at}
              }
            },
            add_label_fun: fn _, _ -> flunk("must not mutate labels while cancelling") end,
            remove_label_fun: fn _, _ -> flunk("must not mutate labels while cancelling") end
          )
        )

      refute Map.has_key?(result.running["1"], :rate_limit_fallback_revert_pending)
      refute Map.has_key?(result.running["1"], :paused_reason)
    end

    test "caps fallback transitions to one running entry per tick" do
      entries =
        Map.new(1..3, fn index ->
          id = Integer.to_string(index)
          issue = %Issue{id: id, identifier: "repo##{id}", labels: []}
          {id, fallback_entry(%{identifier: issue.identifier, issue: issue})}
        end)

      state = %State{running: entries}
      test_pid = self()

      result =
        RateLimitFallback.reconcile(
          state,
          reconcile_opts(
            add_label_fun: fn identifier, label ->
              send(test_pid, {:label_op, {:add, identifier, label}})
              :ok
            end,
            teardown_fun: fn current_state, running_entry, _ ->
              send(test_pid, {:teardown, running_entry.identifier})
              current_state
            end,
            dispatch_fun: fn current_state, issue, _, _ ->
              record_started_dispatch(current_state, issue)
            end
          )
        )

      assert map_size(result.running) == 3
      assert_receive {:teardown, _identifier}
      refute_receive {:teardown, _identifier}
      assert_receive {:label_op, {:add, _, @marker_label}}
      assert_receive {:label_op, {:add, _, "model:claude"}}
      refute_receive {:label_op, _}
    end

    test "caps label attempts when the tracker is failing" do
      entries =
        Map.new(1..3, fn index ->
          id = Integer.to_string(index)
          issue = %Issue{id: id, identifier: "repo##{id}", labels: []}
          {id, fallback_entry(%{identifier: issue.identifier, issue: issue})}
        end)

      state = %State{running: entries}
      test_pid = self()

      assert RateLimitFallback.reconcile(
               state,
               reconcile_opts(
                 add_label_fun: fn identifier, label ->
                   send(test_pid, {:label_op, {:add, identifier, label}})
                   {:error, :tracker_unavailable}
                 end,
                 teardown_fun: fn _, _, _ -> flunk("must not tear down after label failure") end
               )
             ) == state

      assert_receive {:label_op, {:add, _, @marker_label}}
      refute_receive {:label_op, _}
    end

    test "revert removes only the fallback-owned model label" do
      state = fallback_state(["model:codex", "model:claude", @marker_label], "claude")
      test_pid = self()

      _result =
        RateLimitFallback.reconcile(
          state,
          reconcile_opts(
            add_label_fun: fn _, _ -> :ok end,
            remove_label_fun: fn identifier, label ->
              send(test_pid, {:label_op, {:remove, identifier, label}})
              :ok
            end,
            teardown_fun: fn current_state, _, _ -> current_state end,
            dispatch_fun: fn current_state, issue, _, _ ->
              send(test_pid, {:redispatched_issue, issue})
              record_started_dispatch(current_state, issue)
            end
          )
        )

      assert_label_ops([
        {:remove, "repo#1", "model:claude"},
        {:remove, "repo#1", @marker_label}
      ])

      assert_received {:redispatched_issue, %Issue{labels: ["model:codex"], selected_backend: "codex"}}
    end

    test "revert honors an operator route added during fallback" do
      state =
        fallback_state(
          ["model:claude", @marker_label, "model:claude-opus"],
          "claude"
        )

      test_pid = self()

      _result =
        RateLimitFallback.reconcile(
          state,
          reconcile_opts(
            add_label_fun: fn _, _ -> :ok end,
            remove_label_fun: fn _, _ -> :ok end,
            teardown_fun: fn current_state, _, _ -> current_state end,
            dispatch_fun: fn current_state, issue, _, _ ->
              send(test_pid, {:redispatched_issue, issue})
              record_started_dispatch(current_state, issue)
            end
          )
        )

      assert_received {:redispatched_issue, %Issue{labels: ["model:claude-opus"], selected_backend: "claude"}}
    end

    test "ignores running entries without an issue" do
      state = %State{running: %{"1" => %{control: %{status: :paused}}}}

      assert RateLimitFallback.reconcile(state, reconcile_opts()) == state
    end

    test "hands the pause cause to resume so the pause attention can be resolved" do
      # PauseResume reads `:paused_reason` off the entry it is given to emit the
      # matching `agent.attention.paused-<cause>.resolved`. Cancelling a
      # deferred revert used to strip the reason first, so the resolution was
      # skipped and the pause attention stayed active forever.
      issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:claude", @marker_label], selected_backend: "claude"}

      entry =
        fallback_entry(%{
          issue: issue,
          control: %{status: :paused},
          paused_reason: :rate_limit_fallback_recovery,
          rate_limit_fallback_revert_pending: true
        })

      test_pid = self()

      RateLimitFallback.reconcile(
        %State{running: %{issue.id => entry}},
        reconcile_opts(
          # Force the deferred-revert cancel path.
          dispatch_ready_fun: fn _state, _issue, _worker_host -> {:error, :max_concurrent_agents_reached} end,
          resume_fun: fn current_state, resumed_entry ->
            send(test_pid, {:resumed_with, Map.get(resumed_entry, :paused_reason)})
            {{:ok, :resumed}, current_state}
          end
        )
      )

      assert_received {:resumed_with, :rate_limit_fallback_recovery}
    end
  end

  defp fallback_state(labels, selected_backend \\ nil, status \\ :paused) do
    issue = %Issue{id: "1", identifier: "repo#1", labels: labels, selected_backend: selected_backend}

    entry =
      fallback_entry(%{
        identifier: issue.identifier,
        issue: issue,
        control: %{status: status},
        paused_reason: if(status == :paused, do: :usage_limit_exhausted, else: nil)
      })

    %State{running: %{issue.id => entry}}
  end

  defp fallback_entry(overrides) do
    Map.merge(
      %{
        identifier: "repo#1",
        issue: %Issue{id: "1", identifier: "repo#1", labels: []},
        worker_host: "worker-2",
        control: %{status: :paused},
        paused_reason: :usage_limit_exhausted,
        started_at: DateTime.add(DateTime.utc_now(), -3_600, :second)
      },
      overrides
    )
  end

  defp record_started_dispatch(state, issue) do
    entry = %{pid: self(), issue: issue, identifier: issue.identifier}

    %{
      state
      | completed: MapSet.put(state.completed, issue.id),
        running: Map.put(state.running, issue.id, entry)
    }
  end

  defp recovered_state do
    %{
      "backends" => %{
        "codex" => %{
          "limited" => false,
          "available_observed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      }
    }
  end

  defp reconcile_opts(overrides \\ []) do
    Keyword.merge(
      [
        fallback_backend: "claude",
        primary_backend: "codex",
        marker_label: @marker_label,
        current_backend: "codex",
        state: recovered_state(),
        minimum_dwell_seconds: 0,
        backend_ready_fun: fn _backend, _worker_host -> true end,
        dispatch_ready_fun: fn _state, _issue, _worker_host -> :ok end
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
