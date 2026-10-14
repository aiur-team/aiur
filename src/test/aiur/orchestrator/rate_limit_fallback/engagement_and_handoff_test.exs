Code.require_file("fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.RateLimitFallback.EngagementAndHandoffTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport, only: [receive_barrier: 1]

  import Aiur.RateLimitFallbackFixture,
    only: [fallback_state: 1, fallback_state: 2, fallback_entry: 1, record_started_dispatch: 2, reconcile_opts: 0, reconcile_opts: 1, assert_label_ops: 1]

  alias Aiur.Issue
  alias Aiur.Orchestrator.RateLimitFallback
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TrackerTasks

  @marker_label "agent:rate-limit-fallback"

  describe "reconcile/2" do
    test "moves a limit-paused session and resumes it on the selected account" do
      issue = %Issue{id: "1", identifier: "repo#1", labels: []}

      entry =
        fallback_entry(%{
          issue: issue,
          usage_limit_session: %{backend: "claude-repl", account_name: "default", session_id: "session-1", cwd: "/repo"}
        })

      state = %State{running: %{issue.id => entry}}
      config = %{accounts: %{"claude" => ["default", "work"]}, account_selection: "priority"}
      test_pid = self()

      result =
        RateLimitFallback.reconcile(
          state,
          reconcile_opts(
            account_config: config,
            account_list_fun: fn _ -> [%{name: "default"}, %{name: "work"}] end,
            account_usage_fetcher: fn "work" -> %{"seven_day" => 35, "five_hour" => 40} end,
            move_session_fun: fn harness, source, destination, session_id, cwd, _opts ->
              send(test_pid, {:moved, harness, source, destination, session_id, cwd})
              :ok
            end,
            teardown_fun: fn current_state, running_entry, reason ->
              send(test_pid, {:teardown, running_entry.identifier, reason})
              current_state
            end,
            handoff_event_fun: fn event_issue, source, destination, session_id ->
              send(test_pid, {:handoff_event, event_issue.id, source, destination, session_id})
            end,
            dispatch_fun: fn current_state, dispatch_issue, attempt, worker_host, opts ->
              send(test_pid, {:dispatch, dispatch_issue.id, attempt, worker_host, opts})
              record_started_dispatch(current_state, dispatch_issue)
            end
          )
        )

      assert_received {:moved, "claude", "default", "work", "session-1", "/repo"}
      assert_received {:handoff_event, "1", "default", "work", "session-1"}
      assert_received {:teardown, "repo#1", :account_handoff}
      assert_received {:dispatch, "1", nil, "worker-2", [account_name: "work", resume_thread_id: "session-1"]}
      assert result.running["1"].session_execution == %{backend: "claude-repl", account: "work"}
    end

    test "engages the fallback, relabels the issue, and preserves worker affinity on redispatch" do
      state = fallback_state([], "codex")
      test_pid = self()

      result =
        RateLimitFallback.reconcile(
          state,
          reconcile_opts(
            state: %{"backends" => %{}},
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

    test "carries an authoritative lifecycle fence to the live fallback replacement" do
      fence = %{
        generation: 7,
        authoritative_state: "rework",
        pending_item_ids: MapSet.new([872, 874, 887, 891]),
        opened_at: DateTime.utc_now()
      }

      state =
        fallback_state([], "codex")
        |> put_in([Access.key(:running), "1", :lifecycle_fence], fence)
        |> Map.put(:claimed, MapSet.new(["1"]))

      result =
        RateLimitFallback.reconcile(
          state,
          reconcile_opts(
            state: %{"backends" => %{}},
            add_label_fun: fn _, _ -> :ok end,
            teardown_fun: fn current_state, _running_entry, _reason -> current_state end,
            dispatch_fun: fn current_state, issue, _attempt, _worker_host ->
              record_started_dispatch(current_state, issue)
            end
          )
        )

      replacement = result.running["1"]

      assert replacement.lifecycle_fence == fence
      assert replacement.issue.selected_backend == "claude"
      assert result.claimed == MapSet.new(["1"])
    end

    test "removes the inert marker when adding the routing label fails" do
      state = fallback_state([])
      test_pid = self()

      result =
        RateLimitFallback.reconcile(
          state,
          reconcile_opts(
            state: %{"backends" => %{}},
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
        )

      assert result.running == state.running
      assert {1, _deadline} = result.fallback_backoff["1"]

      assert_label_ops([
        {:add, "repo#1", @marker_label},
        {:add, "repo#1", "model:claude"},
        {:remove, "repo#1", @marker_label}
      ])
    end

    test "restores routing when removing the marker fails" do
      state = fallback_state(["model:claude", @marker_label])
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

              if label == @marker_label,
                do: {:error, :marker_remove_failed},
                else: :ok
            end,
            teardown_fun: fn _, _, _ -> flunk("must not tear down after a label-write failure") end,
            dispatch_fun: fn _, _, _, _ -> flunk("must not dispatch after a label-write failure") end
          )
        )

      assert result.running == state.running
      assert {1, _deadline} = result.fallback_backoff["1"]

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

    test "parks a torn-down entry and schedules retry when dispatch unexpectedly no-ops" do
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
            state: %{"backends" => %{}},
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

      assert %{pid: nil, ref: nil, control: %{status: :completed}, rate_limit_fallback_replacement: true} = result.running["1"]
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
            state: %{"backends" => %{}},
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
      assert_receive {:teardown, _identifier}, 1000
      refute_receive {:teardown, _identifier}, 100
      assert_receive {:label_op, {:add, _, @marker_label}}, 1000
      assert_receive {:label_op, {:add, _, "model:claude"}}, 1000
      refute_receive {:label_op, _}, 100
    end

    test "ignores running entries without an issue" do
      state = %State{running: %{"1" => %{control: %{status: :paused}}}}

      assert RateLimitFallback.reconcile(state, reconcile_opts()) == state
    end
  end

  test "pending fallback label writes leave owner responsive and cannot tear down a replaced runner" do
    parent = self()
    owner = {__MODULE__, make_ref()}
    :yes = :global.register_name(owner, parent)
    on_exit(fn -> :global.unregister_name(owner) end)
    state = fallback_state([], "codex")
    state = %{state | snapshot_key: {:global, owner}}

    pending =
      RateLimitFallback.reconcile(
        state,
        reconcile_opts(
          state: %{"backends" => %{}},
          add_label_fun: fn _, label ->
            if label == @marker_label do
              send(parent, {:fallback_writer, self()})

              receive do
                :release -> :ok
              end
            else
              :ok
            end
          end,
          teardown_fun: fn _, _, _ -> flunk("replacement runner was torn down") end
        )
      )

    receive_barrier({:fallback_writer, worker})
    refute worker == self()
    replacement = Map.put(state.running["1"], :session_id, "replacement")
    current = %{pending | running: %{"1" => replacement}, globally_paused: true}
    send(worker, :release)
    receive_barrier({task_ref, result})
    {:handled, applied} = TrackerTasks.result(current, task_ref, result)
    assert applied.running["1"] == replacement
    assert applied.globally_paused
  end
end
