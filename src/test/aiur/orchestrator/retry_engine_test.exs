defmodule Aiur.Orchestrator.RetryEngineTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.{Issue, TrackerIdentity}
  alias Aiur.Orchestrator.{RetryEngine, SnapshotStore, State}
  alias Aiur.Workspace.Ownership

  describe "failure_retry?/1" do
    test "returns false for non-counting delay types" do
      refute RetryEngine.failure_retry?(%{delay_type: :continuation})
      refute RetryEngine.failure_retry?(%{delay_type: :capacity_wait})
      refute RetryEngine.failure_retry?(%{delay_type: :model_limit_wait})
      refute RetryEngine.failure_retry?(%{delay_type: :precondition})
      refute RetryEngine.failure_retry?(%{delay_type: :terminal_verification})
    end

    test "returns true for failure-counted retries" do
      assert RetryEngine.failure_retry?(%{})
      assert RetryEngine.failure_retry?(%{delay_type: :other})
      assert RetryEngine.failure_retry?(%{error: "timeout"})
    end
  end

  describe "retry_delay/2" do
    test "first continuation attempt uses fixed delay" do
      assert RetryEngine.retry_delay(1, %{delay_type: :continuation}) == 1_000
    end

    test "capacity_wait uses fixed delay regardless of attempt" do
      assert RetryEngine.retry_delay(1, %{delay_type: :capacity_wait}) == 1_000
      assert RetryEngine.retry_delay(5, %{delay_type: :capacity_wait}) == 1_000
    end

    test "model_limit_wait uses a bounded polling delay" do
      assert RetryEngine.retry_delay(1, %{delay_type: :model_limit_wait}) >= 10_000
    end

    test "failure attempts use exponential backoff" do
      assert RetryEngine.retry_delay(1, %{}) == 10_000
      assert RetryEngine.retry_delay(2, %{}) == 20_000
      assert RetryEngine.retry_delay(3, %{}) == 40_000
    end
  end

  describe "failure_retry_delay/1" do
    test "doubles every attempt up to the configured cap" do
      assert RetryEngine.failure_retry_delay(1) == 10_000
      assert RetryEngine.failure_retry_delay(2) == 20_000
      assert RetryEngine.failure_retry_delay(3) == 40_000
      # Capped at max_retry_backoff_ms (default 300_000)
      assert RetryEngine.failure_retry_delay(20) == 300_000
    end
  end

  describe "normalize_retry_attempt/1" do
    test "passes through positive integers" do
      assert RetryEngine.normalize_retry_attempt(1) == 1
      assert RetryEngine.normalize_retry_attempt(5) == 5
    end

    test "returns 0 for non-positive, nil, or non-integer" do
      assert RetryEngine.normalize_retry_attempt(0) == 0
      assert RetryEngine.normalize_retry_attempt(-1) == 0
      assert RetryEngine.normalize_retry_attempt(nil) == 0
      assert RetryEngine.normalize_retry_attempt("1") == 0
    end
  end

  describe "next_retry_attempt_from_running/1" do
    test "increments a positive retry_attempt" do
      assert RetryEngine.next_retry_attempt_from_running(%{retry_attempt: 2}) == 3
      assert RetryEngine.next_retry_attempt_from_running(%{retry_attempt: 1}) == 2
    end

    test "returns nil when retry_attempt is absent or zero" do
      assert RetryEngine.next_retry_attempt_from_running(%{retry_attempt: 0}) == nil
      assert RetryEngine.next_retry_attempt_from_running(%{retry_attempt: nil}) == nil
      assert RetryEngine.next_retry_attempt_from_running(%{}) == nil
    end
  end

  describe "pop_retry_attempt_state/3" do
    test "returns attempt, metadata, and cleared state when token matches" do
      token = make_ref()

      state = %State{
        retry_attempts: %{
          "issue-1" => %{
            attempt: 3,
            retry_token: token,
            identifier: "repo#1",
            error: "boom",
            retry_poll_failures: 0,
            worker_host: nil,
            workspace_path: nil,
            tracker_identity: tracker_identity("repo#1")
          }
        }
      }

      assert {:ok, 3, metadata, next_state} =
               RetryEngine.pop_retry_attempt_state(state, "issue-1", token)

      assert metadata.identifier == "repo#1"
      assert metadata.error == "boom"
      assert metadata.tracker_identity == tracker_identity("repo#1")
      refute Map.has_key?(next_state.retry_attempts, "issue-1")
    end

    test "returns :missing when token does not match" do
      token = make_ref()

      state = %State{
        retry_attempts: %{"issue-1" => %{attempt: 1, retry_token: make_ref()}}
      }

      assert RetryEngine.pop_retry_attempt_state(state, "issue-1", token) == :missing
    end

    test "returns :missing when issue_id not in retry_attempts" do
      state = %State{retry_attempts: %{}}
      assert RetryEngine.pop_retry_attempt_state(state, "issue-x", make_ref()) == :missing
    end
  end

  test "publishes the retry engine's final state" do
    issue = %Issue{id: "issue-final", identifier: "MT-FINAL", state: "In Progress", title: "Final retry"}

    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "memory",
      opencode_command: System.find_executable("true")
    )

    Application.put_env(:aiur, :memory_tracker_issues, [issue])

    generation = SnapshotStore.begin_generation(self())
    retry_token = make_ref()

    state = %State{
      snapshot_key: self(),
      snapshot_generation: generation,
      snapshot_ready?: true,
      globally_paused: true,
      claimed: MapSet.new([issue.id]),
      retry_attempts: %{
        issue.id => %{
          attempt: 2,
          identifier: issue.identifier,
          retry_token: retry_token
        }
      }
    }

    assert {:noreply, final_state} = RetryEngine.handle_retry_message(state, issue.id, retry_token)

    assert %{error: "no available orchestrator slots", identifier: "MT-FINAL", retry_token: final_retry_token} =
             final_state.retry_attempts[issue.id]

    refute final_retry_token == retry_token
    Process.cancel_timer(final_state.retry_attempts[issue.id].timer_ref)

    assert eventually(fn ->
             match?(
               {:current, %{retrying: [%{identifier: "MT-FINAL"}]}, _freshness},
               Aiur.Orchestrator.dashboard_snapshot(self(), 1_000)
             )
           end)
  end

  describe "schedule_issue_retry/4" do
    test "stores identity supplied for a newly scheduled retry" do
      identity = tracker_identity("repo#new")

      next =
        RetryEngine.schedule_issue_retry(%State{}, "issue-new", 1, %{
          identifier: "repo#new",
          tracker_identity: identity,
          priority: 1,
          delay_type: :continuation
        })

      retry = next.retry_attempts["issue-new"]
      assert retry.tracker_identity == identity
      assert retry.priority == 1
      Process.cancel_timer(retry.timer_ref)
    end

    test "retains the prior identity across a retry/session reschedule" do
      identity = tracker_identity("repo#2")

      state = %State{
        retry_attempts: %{
          "issue-2" => %{
            attempt: 1,
            timer_ref: nil,
            tracker_identity: identity
          }
        }
      }

      next =
        RetryEngine.schedule_issue_retry(state, "issue-2", 1, %{
          identifier: "repo#2",
          delay_type: :continuation
        })

      retry = next.retry_attempts["issue-2"]
      assert retry.tracker_identity == identity
      Process.cancel_timer(retry.timer_ref)
    end

    test "clears the prior identity when a reschedule explicitly supplies nil" do
      identity = tracker_identity("repo#3")

      state = %State{
        retry_attempts: %{
          "issue-3" => %{attempt: 1, timer_ref: nil, tracker_identity: identity}
        }
      }

      next =
        RetryEngine.schedule_issue_retry(state, "issue-3", 1, %{
          identifier: "repo#3",
          tracker_identity: nil,
          delay_type: :continuation
        })

      retry = next.retry_attempts["issue-3"]
      assert retry.tracker_identity == nil
      Process.cancel_timer(retry.timer_ref)
    end
  end

  describe "retry_exhausted alert (#1317)" do
    test "give-up alert includes the underlying error, not just a generic headline" do
      # The Publisher contamination filter's tracked_fn is process-global
      # (:persistent_term) and can be left pointed at another test's narrow
      # set; reset it so this ticket's alert isn't silently filtered.
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("ticket.MT-ALERT-1.agent.retry_exhausted")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      RetryEngine.schedule_issue_retry(%State{}, "issue-alert-1", Config.max_retry_attempts() + 1, %{
        identifier: "MT-ALERT-1",
        # Mirrors what handle_agent_down/3 records: "agent exited: #{inspect(reason)}".
        error: "agent exited: {:workspace_git_metadata_unwritable, \"/ws/.aiur-git-index-write-probe-1\", {:git_index_probe_failed, 128}}",
        delay_type: :failure
      })

      assert_receive {:event, %{topic: "ticket.MT-ALERT-1.agent.retry_exhausted"} = event}, 500
      refute event["message"] == "Agent retry budget exhausted"
      assert event["message"] =~ "git_index_probe_failed"
      assert event["reason"] =~ "git_index_probe_failed"
    end
  end

  defp tracker_identity(identifier) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "I_kwDO#{identifier}",
      identifier: identifier,
      reason: nil
    }
  end

  describe "complete_issue/2" do
    test "adds to completed and removes from retry_attempts" do
      state = %State{
        completed: MapSet.new(),
        retry_attempts: %{"issue-1" => %{attempt: 1}}
      }

      result = RetryEngine.complete_issue(state, "issue-1")

      assert MapSet.member?(result.completed, "issue-1")
      refute Map.has_key?(result.retry_attempts, "issue-1")
    end
  end

  describe "release_issue_claim/2" do
    test "removes the issue_id from claimed" do
      state = %State{claimed: MapSet.new(["issue-1", "issue-2"])}
      result = RetryEngine.release_issue_claim(state, "issue-1")

      refute MapSet.member?(result.claimed, "issue-1")
      assert MapSet.member?(result.claimed, "issue-2")
    end
  end

  describe "workspace ownership contention" do
    test "releases a contender when ownership was released before its wait row was installed" do
      issue_id = "issue-ownership-race"
      identifier = "repo#ownership-race-#{System.unique_integer([:positive])}"

      state = %State{
        claimed: MapSet.new([issue_id]),
        dispatch_recovery: %{
          workspace_ownership: %{waits: %{}, ready: %{}},
          codex_thrash_budget: %{}
        }
      }

      next =
        RetryEngine.wait_for_workspace_ownership(
          state,
          issue_id,
          identifier,
          :none,
          :waiting
        )

      refute MapSet.member?(next.claimed, issue_id)
      assert Map.has_key?(next.dispatch_recovery.workspace_ownership.ready, issue_id)
    end

    test "re-subscribes when ownership changes hands before its wait row is installed" do
      issue_id = "issue-ownership-handoff"
      identifier = "repo#ownership-handoff-#{System.unique_integer([:positive])}"
      assert {:ok, first_owner} = Ownership.claim(identifier)

      on_exit(fn -> Ownership.release(first_owner) end)

      # This is the runner's original subscription. Its availability notice is
      # deliberately consumed before the orchestrator installs the row.
      assert {:waiting, _guardian, _generation} = Ownership.wait_for_release(identifier, self())
      assert :ok = Ownership.release(first_owner)
      assert_receive {:workspace_ownership_available, ^identifier, _guardian, _generation}

      assert {:ok, second_owner} = Ownership.claim(identifier)
      on_exit(fn -> Ownership.release(second_owner) end)

      state = %State{
        claimed: MapSet.new([issue_id]),
        dispatch_recovery: %{
          workspace_ownership: %{waits: %{}, ready: %{}},
          codex_thrash_budget: %{}
        }
      }

      next =
        RetryEngine.wait_for_workspace_ownership(
          state,
          issue_id,
          identifier,
          first_owner,
          :waiting
        )

      assert MapSet.member?(next.claimed, issue_id)
      assert :ok = Ownership.release(second_owner)
      assert_receive {:workspace_ownership_available, ^identifier, _guardian, _generation}
    end

    test "parks a contender without consuming retry or thrash budget when its runner exits first" do
      issue_id = "issue-ownership"
      identifier = "repo#ownership-#{System.unique_integer([:positive])}"
      assert {:ok, owner_lease} = Ownership.claim(identifier)

      on_exit(fn -> Ownership.release(owner_lease) end)

      runner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      ref = Process.monitor(runner)
      exit_ref = Process.monitor(runner)
      retry_token = make_ref()
      timer_ref = Process.send_after(self(), :unexpected_retry, 60_000)

      state = %State{
        running: %{
          issue_id => %{
            pid: runner,
            ref: ref,
            identifier: identifier,
            worker_host: "worker-a",
            prior_work: true,
            workspace_path: "/workspaces/ownership"
          }
        },
        completed: MapSet.new([issue_id]),
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{
          issue_id => %{timer_ref: timer_ref, retry_token: retry_token, attempt: 1}
        },
        dispatch_recovery: %{
          workspace_ownership: %{waits: %{}, ready: %{}},
          codex_thrash_budget: %{issue_id => %{window_start_ms: 0, count: 4}}
        }
      }

      waiting =
        RetryEngine.wait_for_workspace_ownership(
          state,
          issue_id,
          identifier,
          {:ok, owner_lease},
          :waiting
        )

      refute Map.has_key?(waiting.running, issue_id)
      refute Map.has_key?(waiting.retry_attempts, issue_id)
      refute MapSet.member?(waiting.completed, issue_id)
      assert MapSet.member?(waiting.claimed, issue_id)

      assert waiting.dispatch_recovery.workspace_ownership.waits[identifier].owner ==
               {:ok, owner_lease}

      assert waiting.dispatch_recovery.workspace_ownership.waits[identifier].prior_work
      assert waiting.dispatch_recovery.codex_thrash_budget == state.dispatch_recovery.codex_thrash_budget

      ready = RetryEngine.release_workspace_wait(waiting, identifier)
      refute MapSet.member?(ready.claimed, issue_id)
      assert Map.has_key?(ready.dispatch_recovery.workspace_ownership.ready, issue_id)
      assert ready.dispatch_recovery.workspace_ownership.ready[issue_id].worker_host == "worker-a"
      assert ready.dispatch_recovery.workspace_ownership.ready[issue_id].retry_attempt == 1
      assert ready.dispatch_recovery.workspace_ownership.ready[issue_id].prior_work
      assert ready.dispatch_recovery.workspace_ownership.ready[issue_id].workspace_path == "/workspaces/ownership"
      assert ready.dispatch_recovery.codex_thrash_budget == state.dispatch_recovery.codex_thrash_budget

      Process.exit(runner, :kill)
      assert_receive {:DOWN, ^exit_ref, :process, ^runner, :killed}, 2_000
      refute_receive :unexpected_retry
    end

    test "rejects a stale guardian release and preserves a DOWN-first retry envelope" do
      issue_id = "issue-ownership-down-first"
      identifier = "repo#ownership-down-first-#{System.unique_integer([:positive])}"
      assert {:ok, owner_lease} = Ownership.claim(identifier)
      on_exit(fn -> Ownership.release(owner_lease) end)

      state = %State{
        running: %{
          issue_id => %{
            ref: make_ref(),
            identifier: identifier,
            started_at: DateTime.utc_now(),
            retry_attempt: 2,
            worker_host: "worker-a",
            workspace_path: "/workspaces/ownership"
          }
        },
        claimed: MapSet.new([issue_id]),
        dispatch_recovery: %{
          workspace_ownership: %{waits: %{}, ready: %{}},
          codex_thrash_budget: %{}
        }
      }

      ref = state.running[issue_id].ref
      assert {:noreply, after_down} = RetryEngine.handle_agent_down(state, ref, :killed)
      assert %{attempt: 3, worker_host: "worker-a"} = after_down.retry_attempts[issue_id]

      waiting =
        RetryEngine.wait_for_workspace_ownership(
          after_down,
          issue_id,
          identifier,
          {:ok, owner_lease},
          {:waiting, owner_lease.guardian, owner_lease.generation}
        )

      assert %{retry_attempt: 3, worker_host: "worker-a"} =
               waiting.dispatch_recovery.workspace_ownership.waits[identifier]

      stale = RetryEngine.release_workspace_wait(waiting, identifier, self(), owner_lease.generation - 1)
      assert MapSet.member?(stale.claimed, issue_id)
      assert stale.dispatch_recovery.workspace_ownership.ready == %{}

      ready =
        RetryEngine.release_workspace_wait(
          waiting,
          identifier,
          owner_lease.guardian,
          owner_lease.generation
        )

      refute MapSet.member?(ready.claimed, issue_id)
      assert %{retry_attempt: 3, worker_host: "worker-a"} = ready.dispatch_recovery.workspace_ownership.ready[issue_id]
    end
  end

  describe "preserve_running_issue_on_external_error/2" do
    test "refreshes the issue while preserving the live runner and claim" do
      issue_id = "issue-error"

      running_issue = %Issue{
        id: issue_id,
        identifier: "ERR-1",
        state: "in-progress",
        title: "Preserve the runner"
      }

      reported_issue = %{running_issue | state: "error"}

      running_entry = %{
        issue: running_issue,
        identifier: running_issue.identifier,
        control: %{status: :working},
        marker: :preserved
      }

      state = %State{
        running: %{issue_id => running_entry},
        claimed: MapSet.new([issue_id])
      }

      result = RetryEngine.preserve_running_issue_on_external_error(state, reported_issue)

      assert result.running[issue_id].issue == reported_issue
      assert result.running[issue_id].marker == :preserved
      assert result.running[issue_id].control.status == :working
      assert result.claimed == state.claimed
    end
  end

  describe "handle_retry_issue_lookup/6" do
    test "preserves prior-work continuation through an active retry dispatch" do
      issue = %Issue{id: "issue-active", identifier: "27", title: "Active retry", state: "In Progress"}
      state = %State{max_concurrent_agents: 1, effective_concurrent_agents: 1}
      parent = self()

      assert {:noreply, next_state} =
               RetryEngine.handle_retry_issue_lookup(
                 issue,
                 state,
                 issue.id,
                 2,
                 %{worker_host: nil, prior_work: true},
                 terminal_states: MapSet.new(["done"]),
                 dispatch_fun: fn current_state, ^issue, 2, nil, dispatch_opts ->
                   send(parent, {:retry_dispatch_opts, dispatch_opts})

                   %{
                     current_state
                     | running: Map.put(current_state.running, issue.id, %{pid: parent})
                   }
                 end
               )

      assert_receive {:retry_dispatch_opts, dispatch_opts}
      assert dispatch_opts[:prior_work] == true
      assert get_in(next_state.running, [issue.id, :pid]) == parent
    end

    test "reschedules when an active retry dispatch starts neither a runner nor a retry" do
      issue = %Issue{id: "issue-limited", identifier: "27", title: "Limited retry", state: "In Progress"}

      state = %State{
        claimed: MapSet.new([issue.id]),
        max_concurrent_agents: 1,
        effective_concurrent_agents: 1
      }

      assert {:noreply, next_state} =
               RetryEngine.handle_retry_issue_lookup(
                 issue,
                 state,
                 issue.id,
                 2,
                 %{worker_host: nil, workspace_path: "/tmp/issue-limited", prior_work: true},
                 terminal_states: MapSet.new(["done"]),
                 dispatch_fun: fn current_state, ^issue, 2, nil, _dispatch_opts ->
                   %{
                     current_state
                     | model_fallback_waiting: MapSet.put(current_state.model_fallback_waiting, issue.id)
                   }
                 end,
                 schedule_retry_fun: fn retry_state, issue_id, attempt, metadata ->
                   assert attempt == 2
                   assert metadata.delay_type == :model_limit_wait
                   assert metadata.prior_work == true

                   %{
                     retry_state
                     | retry_attempts: Map.put(retry_state.retry_attempts, issue_id, metadata)
                   }
                 end
               )

      assert MapSet.member?(next_state.claimed, issue.id)
      assert MapSet.member?(next_state.model_fallback_waiting, issue.id)
      assert Map.has_key?(next_state.retry_attempts, issue.id)
    end

    test "fetches and records a terminal retry ticket when active candidates omit it" do
      terminal = %Issue{
        id: "issue-terminal",
        identifier: "27",
        state: "done",
        tracker_identity: tracker_identity("27")
      }

      state = %State{claimed: MapSet.new([terminal.id])}
      parent = self()
      identity = terminal.tracker_identity

      assert {:ok, ^terminal} =
               RetryEngine.fetch_retry_issue([], terminal.id, fn ["issue-terminal"] ->
                 {:ok, [terminal]}
               end)

      assert {:noreply, next_state} =
               RetryEngine.handle_retry_issue_lookup(
                 terminal,
                 state,
                 terminal.id,
                 1,
                 %{worker_host: nil},
                 terminal_states: MapSet.new(["done"]),
                 observe_membership_fun: fn identity, lifecycle ->
                   send(parent, {:membership_recorded, identity, lifecycle})
                   :ok
                 end,
                 set_terminal_verification_pending_fun: fn _identity, _pending? -> :ok end,
                 cleanup_terminal_issue_artifacts_fun: fn _identifier, _worker_host ->
                   assert_receive {:membership_recorded, ^identity, :completed}
                   :ok
                 end
               )

      refute MapSet.member?(next_state.claimed, terminal.id)
    end

    test "reports a failed by-id retry lookup instead of releasing the claim" do
      assert {:error, :temporarily_unavailable} =
               RetryEngine.fetch_retry_issue([], "issue-terminal", fn ["issue-terminal"] ->
                 {:error, :temporarily_unavailable}
               end)
    end

    test "records terminal membership before cleanup and claim release" do
      issue = %Issue{
        id: "issue-terminal",
        identifier: "27",
        state: "done",
        tracker_identity: tracker_identity("27")
      }

      state = %State{claimed: MapSet.new([issue.id])}
      parent = self()
      identity = issue.tracker_identity

      assert {:noreply, next_state} =
               RetryEngine.handle_retry_issue_lookup(
                 issue,
                 state,
                 issue.id,
                 1,
                 %{worker_host: nil},
                 terminal_states: MapSet.new(["done"]),
                 observe_membership_fun: fn identity, lifecycle ->
                   send(parent, {:membership_recorded, identity, lifecycle})
                   :ok
                 end,
                 cleanup_terminal_issue_artifacts_fun: fn _identifier, _worker_host ->
                   assert_receive {:membership_recorded, ^identity, :completed}
                   :ok
                 end
               )

      refute MapSet.member?(next_state.claimed, issue.id)
    end

    test "retains a terminal retry claim when membership persistence fails" do
      issue = %Issue{
        id: "issue-terminal",
        identifier: "27",
        state: "done",
        tracker_identity: tracker_identity("27")
      }

      parent = self()
      state = %State{claimed: MapSet.new([issue.id])}

      assert {:noreply, next_state} =
               RetryEngine.handle_retry_issue_lookup(
                 issue,
                 state,
                 issue.id,
                 1,
                 %{worker_host: nil},
                 terminal_states: MapSet.new(["done"]),
                 observe_membership_fun: fn _identity, _lifecycle -> {:error, :disk_full} end,
                 mark_reconciled_fun: fn status -> send(parent, {:freshness, status}) end,
                 set_terminal_verification_pending_fun: fn _identity, pending? ->
                   send(parent, {:terminal_verification_pending, pending?})
                 end,
                 cleanup_terminal_issue_artifacts_fun: fn _identifier, _worker_host ->
                   flunk("must not clean up before terminal membership persists")
                 end
               )

      assert_receive {:freshness, :unavailable}
      assert_receive {:terminal_verification_pending, true}
      assert MapSet.member?(next_state.claimed, issue.id)
      assert Map.has_key?(next_state.retry_attempts, issue.id)
    end
  end

  describe "prior_work_for_retry?/2" do
    test "does not turn a fresh zero-turn launch failure into prior work" do
      refute RetryEngine.prior_work_for_retry?(%{prior_work: false, completed_turn_count: 0}, true)
    end

    test "preserves explicit recycle provenance and completed work" do
      assert RetryEngine.prior_work_for_retry?(%{prior_work: true, completed_turn_count: 0}, true)
      assert RetryEngine.prior_work_for_retry?(%{prior_work: false, completed_turn_count: 1}, true)
      refute RetryEngine.prior_work_for_retry?(%{prior_work: true, completed_turn_count: 1}, false)
    end
  end

  defp eventually(fun, attempts \\ 30)

  defp eventually(fun, attempts) when is_function(fun, 0) and attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
