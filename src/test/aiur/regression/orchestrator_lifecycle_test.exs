defmodule Aiur.Regression.OrchestratorLifecycleTest do
  use Aiur.TestSupport

  @moduledoc """
  These tests pin `Aiur.Orchestrator` lifecycle behavior prior to the T-022..T-027
  decomposition and must pass unmodified through every extraction wave.
  """

  alias Aiur.Events.SubscriptionStore

  defmodule HermeticReworkGitHubClient do
    def update_issue_state(issue_id, state_name) do
      if is_pid(recipient()), do: send(recipient(), {:hermetic_rework_update, issue_id, state_name})

      Agent.get_and_update(agent(), fn
        [result | rest] -> {result, rest}
        [] -> {:ok, []}
      end)
    end

    def fetch_issue_states_by_ids(issue_ids) do
      wanted = MapSet.new(issue_ids)
      {:ok, Enum.filter(issues(), &(&1.id in wanted or &1.identifier in wanted))}
    end

    def fetch_candidate_issues, do: {:ok, issues()}

    def hydrate_blocked_by(issue), do: {:ok, issue}

    def fetch_classified_issue_comments(_issue_id), do: {:ok, []}

    def fetch_open_pull_request_for_branch(_issue_id), do: {:ok, nil}

    defp agent, do: Application.fetch_env!(:aiur, :hermetic_rework_agent)
    defp issues, do: Application.get_env(:aiur, :hermetic_rework_issues, [])
    defp recipient, do: Application.get_env(:aiur, :hermetic_rework_recipient)
  end

  defmodule ResumeRefreshGitHubClient do
    def fetch_issue_states_by_ids(_issue_ids) do
      Agent.get_and_update(agent(), fn [result | rest] -> {result, rest} end)
    end

    def remove_label(issue_identifier, label) do
      send(recipient(), {:resume_refresh_remove_label, issue_identifier, label})
      :ok
    end

    defp agent, do: Application.fetch_env!(:aiur, :resume_refresh_agent)
    defp recipient, do: Application.fetch_env!(:aiur, :resume_refresh_recipient)
  end

  defp running_entry(issue_id, identifier, status) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{id: issue_id, identifier: identifier, state: "In Progress", title: nil},
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: status},
      session_id: "thread-#{identifier}",
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      started_at: DateTime.utc_now()
    }
  end

  defp start_orchestrator(name) do
    unless Process.whereis(Aiur.Supervisor) do
      {:ok, _apps} = Application.ensure_all_started(:aiur)
    end

    {:ok, pid} = Orchestrator.start_link(name: name, initial_poll?: false)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
    pid
  end

  defp worker_pid do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: send(pid, :stop) end)
    pid
  end

  defp base_state(attrs \\ []) do
    struct!(
      Orchestrator.State,
      Keyword.merge(
        [
          running: %{},
          claimed: MapSet.new(),
          retry_attempts: %{},
          max_concurrent_agents: 6,
          session_max_concurrent_agents: nil,
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
        ],
        attrs
      )
    )
  end

  defp todo_issue(id), do: %Issue{id: id, identifier: id, state: "todo", title: "Todo"}

  defp review_issue(id),
    do: %Issue{id: id, identifier: id, state: "human-review", title: "Review"}

  defp memory_tracker!(issues) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress", "human-review", "rework", "merging"],
      tracker_terminal_states: ["done", "cancelled", "canceled"]
    )

    Application.put_env(:aiur, :memory_tracker_recipient, self())
    Application.put_env(:aiur, :memory_tracker_issues, issues)
  end

  defp resume_refresh_tracker!(responses) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent",
      tracker_active_states: ["todo", "in-progress", "human-review", "rework", "merging"],
      tracker_terminal_states: ["done", "cancelled", "canceled"]
    )

    {:ok, agent} = Agent.start_link(fn -> responses end)
    previous_client = Application.get_env(:aiur, :github_client_module)
    Application.put_env(:aiur, :github_client_module, ResumeRefreshGitHubClient)
    Application.put_env(:aiur, :resume_refresh_agent, agent)
    Application.put_env(:aiur, :resume_refresh_recipient, self())

    on_exit(fn ->
      restore_app_env(:github_client_module, previous_client)
      Application.delete_env(:aiur, :resume_refresh_agent)
      Application.delete_env(:aiur, :resume_refresh_recipient)
    end)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)

  defp isolated_subscription_store(identifier) do
    tmp_dir = Path.join(System.tmp_dir!(), "aiur_reg_orc_life_#{System.unique_integer([:positive])}")
    original = Application.get_env(:aiur, :log_file)
    File.mkdir_p!(tmp_dir)
    Application.put_env(:aiur, :log_file, Path.join(tmp_dir, "aiur.log"))

    on_exit(fn ->
      SubscriptionStore.stop(identifier)
      if original, do: Application.put_env(:aiur, :log_file, original), else: Application.delete_env(:aiur, :log_file)
      File.rm_rf(tmp_dir)
    end)
  end

  defp comment_event(identifier, topic, trusted? \\ true, body \\ "please rework") do
    %{
      id: System.unique_integer([:positive]),
      topic: "ticket.#{identifier}.#{topic}",
      source: :github,
      author_trusted?: trusted?,
      message: body,
      comment: %{"body" => body}
    }
  end

  describe "comment wake/rework transitions" do
    setup do
      previous_loadavg = Application.get_env(:aiur, :loadavg_source_override)
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1"} end)

      on_exit(fn -> restore_app_env(:loadavg_source_override, previous_loadavg) end)
    end

    test "trusted PR review comment reactivates a deactivated entry to rework" do
      issue_id = "life-review-1"
      identifier = "7411"
      memory_tracker!([%Issue{id: issue_id, identifier: identifier, state: "human-review", title: "Fix"}])

      entry =
        running_entry(issue_id, identifier, :deactivated)
        |> put_in([:issue], %Issue{id: issue_id, identifier: identifier, state: "human-review"})

      state = base_state(running: %{issue_id => entry}, claimed: MapSet.new([issue_id]))

      assert {:noreply, next} =
               Orchestrator.handle_info({:event, comment_event(identifier, "pr.review_comment")}, state)

      assert_receive {:memory_tracker_state_update, ^issue_id, "rework"}, 2000
      refute get_in(next.running[issue_id], [:control, :status]) == :deactivated
    end

    test "trusted comment on an idle issue promotes it to rework and dispatches immediately" do
      identifier = "7412"
      isolated_subscription_store(identifier)
      memory_tracker!([review_issue(identifier)])

      assert {:noreply, next} =
               Orchestrator.handle_info({:event, comment_event(identifier, "issue.commented")}, base_state())

      assert_receive {:memory_tracker_state_update, ^identifier, "rework"}, 2000
      assert MapSet.member?(next.claimed, identifier)
    end

    # An over-threshold load average alone is not enough: the gate corroborates
    # it against a measured `/proc/stat` window, so the state carries the
    # previous snapshot a polling orchestrator would already have and the source
    # advances almost entirely in non-idle time (#2089).
    test "trusted comment rework dispatch respects the load admission gate" do
      identifier = "7412-load-hold"
      schedulers = System.schedulers_online()
      previous_loadavg = Application.get_env(:aiur, :loadavg_source_override)
      previous_proc_stat = Application.get_env(:aiur, :proc_stat_source_override)

      Application.put_env(:aiur, :loadavg_source_override, fn ->
        {:ok, "#{schedulers * 2.0} 1.0 1.0 1/1 1"}
      end)

      Application.put_env(:aiur, :proc_stat_source_override, fn ->
        {:ok, "cpu  1100 100 0 710 0 0 0 0 0 0\nprocs_running 20\n"}
      end)

      on_exit(fn ->
        restore_app_env(:loadavg_source_override, previous_loadavg)
        restore_app_env(:proc_stat_source_override, previous_proc_stat)
      end)

      isolated_subscription_store(identifier)
      memory_tracker!([review_issue(identifier)])

      state =
        base_state(
          load_envelope_state: %{
            last_decrease_ms: nil,
            cpu_snapshot: %{total: 1_000, idle: 700, nice: 100, runnable: 20},
            bootstrap_complete?: true
          }
        )

      assert {:noreply, next} =
               Orchestrator.handle_info({:event, comment_event(identifier, "issue.commented")}, state)

      assert_receive {:memory_tracker_state_update, ^identifier, "rework"}, 2000
      refute MapSet.member?(next.claimed, identifier)
      assert %{signal: :load, measured: measured, threshold: threshold} = next.capacity_hold
      assert measured == schedulers * 2.0
      assert threshold == schedulers * 1.5
    end

    test "untrusted-author comment is ignored" do
      issue_id = "life-review-3"
      identifier = "7413"
      memory_tracker!([%Issue{id: issue_id, identifier: identifier, state: "human-review"}])
      entry = running_entry(issue_id, identifier, :deactivated)
      state = base_state(running: %{issue_id => entry}, claimed: MapSet.new([issue_id]))

      assert {:noreply, next} =
               Orchestrator.handle_info({:event, comment_event(identifier, "pr.review_comment", false)}, state)

      refute_receive {:memory_tracker_state_update, ^issue_id, "rework"}, 100
      assert get_in(next.running[issue_id], [:control, :status]) == :deactivated
      assert next.claimed == state.claimed
    end

    test "bot review-pass comment never self-triggers rework" do
      identifier = "7414"
      isolated_subscription_store(identifier)
      memory_tracker!([review_issue(identifier)])
      event = comment_event(identifier, "issue.commented", true, "[codex] Review passed for commit abc123")

      assert {:noreply, next} = Orchestrator.handle_info({:event, event}, base_state())

      refute_receive {:memory_tracker_state_update, ^identifier, "rework"}, 100
      refute MapSet.member?(next.claimed, identifier)
    end

    test "transient tracker failure retries the wake without consuming the event" do
      identifier = "7415"
      isolated_subscription_store(identifier)
      previous_github_client = Application.get_env(:aiur, :github_client_module)
      previous_recipient = Application.get_env(:aiur, :hermetic_rework_recipient)
      previous_agent = Application.get_env(:aiur, :hermetic_rework_agent)
      previous_issues = Application.get_env(:aiur, :hermetic_rework_issues)
      previous_delay = Application.get_env(:aiur, :comment_rework_retry_delay_ms)
      {:ok, agent} = Agent.start_link(fn -> [{:error, {:github_api_status, 502}}, :ok] end)

      Application.put_env(:aiur, :comment_rework_retry_delay_ms, 0)

      on_exit(fn ->
        restore_app_env(:github_client_module, previous_github_client)
        restore_app_env(:hermetic_rework_recipient, previous_recipient)
        restore_app_env(:hermetic_rework_agent, previous_agent)
        restore_app_env(:hermetic_rework_issues, previous_issues)
        restore_app_env(:comment_rework_retry_delay_ms, previous_delay)
        Aiur.TestSupport.safe_stop(agent)
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_active_states: ["todo", "in-progress", "human-review", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      Application.put_env(:aiur, :github_client_module, HermeticReworkGitHubClient)
      Application.put_env(:aiur, :hermetic_rework_recipient, self())
      Application.put_env(:aiur, :hermetic_rework_agent, agent)

      Application.put_env(:aiur, :hermetic_rework_issues, [
        %Issue{id: identifier, identifier: identifier, state: "rework", title: "Rework"}
      ])

      event = comment_event(identifier, "issue.commented")
      assert {:noreply, next} = Orchestrator.handle_info({:event, event}, base_state())
      assert_receive {:hermetic_rework_update, ^identifier, "rework"}, 2000
      assert_receive {:retry_comment_rework, ^identifier, "issue comment", ^event, 2}, 2000

      assert {:noreply, retried} =
               Orchestrator.handle_info({:retry_comment_rework, identifier, "issue comment", event, 2}, next)

      assert_receive {:hermetic_rework_update, ^identifier, "rework"}, 2000
      assert MapSet.member?(retried.claimed, identifier)
    end

    # #1747: the retry chain runs on the long-lived orchestrator for ~60s at the
    # default delays. A missing token cannot clear by being asked five more
    # times, so retrying it only sprays warnings across every test that happens
    # to be running a global `capture_log` assertion at the time.
    test "permanent tracker auth failure fails fast instead of scheduling a retry" do
      identifier = "7417"
      isolated_subscription_store(identifier)
      previous_github_client = Application.get_env(:aiur, :github_client_module)
      previous_recipient = Application.get_env(:aiur, :hermetic_rework_recipient)
      previous_agent = Application.get_env(:aiur, :hermetic_rework_agent)
      previous_issues = Application.get_env(:aiur, :hermetic_rework_issues)
      previous_delay = Application.get_env(:aiur, :comment_rework_retry_delay_ms)
      {:ok, agent} = Agent.start_link(fn -> [{:error, :missing_github_token}, :ok] end)

      Application.put_env(:aiur, :comment_rework_retry_delay_ms, 0)

      on_exit(fn ->
        restore_app_env(:github_client_module, previous_github_client)
        restore_app_env(:hermetic_rework_recipient, previous_recipient)
        restore_app_env(:hermetic_rework_agent, previous_agent)
        restore_app_env(:hermetic_rework_issues, previous_issues)
        restore_app_env(:comment_rework_retry_delay_ms, previous_delay)
        Aiur.TestSupport.safe_stop(agent)
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_active_states: ["todo", "in-progress", "human-review", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      Application.put_env(:aiur, :github_client_module, HermeticReworkGitHubClient)
      Application.put_env(:aiur, :hermetic_rework_recipient, self())
      Application.put_env(:aiur, :hermetic_rework_agent, agent)

      Application.put_env(:aiur, :hermetic_rework_issues, [
        %Issue{id: identifier, identifier: identifier, state: "rework", title: "Rework"}
      ])

      event = comment_event(identifier, "issue.commented")

      log =
        capture_log(fn ->
          assert {:noreply, next} = Orchestrator.handle_info({:event, event}, base_state())
          assert_receive {:hermetic_rework_update, ^identifier, "rework"}, 2000
          send(self(), {:permanent_failure_state, next})
        end)

      assert_receive {:permanent_failure_state, next}

      refute_receive {:retry_comment_rework, ^identifier, "issue comment", ^event, _attempt}, 200
      assert next.comment_rework_retries == %{}
      assert log =~ "rework transition failed permanently"
      refute log =~ "rework transition retry scheduled"
    end

    test "pr.merged terminalizes the ticket to done and tears down the running entry" do
      issue_id = "7416"
      identifier = "7416"
      memory_tracker!([])
      entry = Map.put(running_entry(issue_id, identifier, :working), :pid, worker_pid())
      state = base_state(running: %{issue_id => entry}, claimed: MapSet.new([issue_id]))

      assert {:noreply, next} =
               Orchestrator.handle_info({:event, %{topic: "ticket.#{identifier}.pr.merged"}}, state)

      assert_receive {:memory_tracker_state_update, ^identifier, "done"}, 2000
      refute Map.has_key?(next.running, issue_id)
      refute MapSet.member?(next.claimed, issue_id)
    end
  end

  describe "pause/resume semantics" do
    test "pause.request parks a working entry and stamps paused_at" do
      name = Module.concat(__MODULE__, :PauseRequest)
      pid = start_orchestrator(name)
      entry = running_entry("l7", "L7", :working)
      :sys.replace_state(pid, &%{&1 | running: %{"l7" => entry}})

      assert {:ok, request_id} = Orchestrator.pause_agent(name, "L7")
      assert_receive {:pause_agent, ^request_id}, 2000
      entry = :sys.get_state(pid).running["l7"]
      assert get_in(entry, [:control, :status]) == :paused
      assert %DateTime{} = entry.paused_at
    end

    test "a paused entry keeps its slot and holds new dispatch" do
      state = base_state(max_concurrent_agents: 1, running: %{"l8" => running_entry("l8", "L8", :paused)})
      assert Orchestrator.slot_status_for_test(state) == %{active: 0, paused: 1}
      refute Orchestrator.should_dispatch_issue_for_test(todo_issue("fresh-l8"), state)
    end

    test "resume of a paused entry bypasses available_slots" do
      name = Module.concat(__MODULE__, :ResumeBypass)
      pid = start_orchestrator(name)
      entry = running_entry("l9", "L9", :paused)
      :sys.replace_state(pid, &%{&1 | session_max_concurrent_agents: 1, running: %{"l9" => entry}})

      assert {:ok, :resumed} = Orchestrator.resume_agent(name, "L9")
      assert_receive {:resume_agent, request_id} when is_integer(request_id), 2000
    end

    test "resume is refused when active count already fills the cap" do
      name = Module.concat(__MODULE__, :ResumeBlocked)
      pid = start_orchestrator(name)
      running = %{"active" => running_entry("active", "L10A", :working), "paused" => running_entry("paused", "L10P", :paused)}
      :sys.replace_state(pid, &%{&1 | session_max_concurrent_agents: 1, running: running})

      assert {:error, :max_concurrent_agents_reached} = Orchestrator.resume_agent(name, "L10P")
      refute_receive {:resume_agent, _}, 100
    end

    test "resume with no running entry clears tracker pause and starts a queued idle issue" do
      name = Module.concat(__MODULE__, :ResumeQueued)
      pid = start_orchestrator(name)

      issue =
        "L11"
        |> todo_issue()
        |> Map.put(:paused, true)
        |> Map.put(:labels, ["agent:todo", "agent:paused"])

      # The tracker still carries `agent:paused`, so the authoritative re-read
      # agrees with the cache and the resume has a real override to clear.
      memory_tracker!([issue])
      :sys.replace_state(pid, &%{&1 | last_polled_issues: %{issue.id => issue}, running: %{}, claimed: MapSet.new()})

      assert {:ok, :started} = Orchestrator.resume_agent(name, issue.identifier)
      assert_receive {:memory_tracker_remove_label, "L11", "agent:paused"}
      assert MapSet.member?(:sys.get_state(pid).claimed, issue.id)
      refute :sys.get_state(pid).last_polled_issues[issue.id].paused
    end

    test "resume refreshes stale cached tracker state before deciding dispatchability" do
      name = Module.concat(__MODULE__, :ResumeStaleCachedState)
      pid = start_orchestrator(name)
      tracker_issue = todo_issue("L11-STALE")
      cached_issue = %{tracker_issue | state: "ci-wait"}
      memory_tracker!([tracker_issue])

      :sys.replace_state(pid, fn state ->
        %{
          state
          | last_polled_issues: %{cached_issue.id => cached_issue},
            candidate_snapshot_fresh?: false,
            running: %{},
            claimed: MapSet.new()
        }
      end)

      assert {:ok, :started} = Orchestrator.resume_agent(name, tracker_issue.identifier)
      state = :sys.get_state(pid)
      assert state.last_polled_issues[tracker_issue.id].state == "todo"
      assert MapSet.member?(state.claimed, tracker_issue.id)
    end

    test "resume names a stale-cache rejection with the tracker state" do
      name = Module.concat(__MODULE__, :ResumeStaleRejection)
      pid = start_orchestrator(name)
      cached_issue = todo_issue("L11-REJECT")
      tracker_issue = %{cached_issue | state: "ci-wait"}
      memory_tracker!([tracker_issue])

      :sys.replace_state(pid, fn state ->
        %{state | last_polled_issues: %{cached_issue.id => cached_issue}, running: %{}, claimed: MapSet.new()}
      end)

      assert {:error, {:stale_tracker_state, {:tracker_state_not_resumable, "ci-wait"}, %{cached_state: "todo", tracker_state: "ci-wait"}}} =
               Orchestrator.resume_agent(name, cached_issue.identifier)

      assert :sys.get_state(pid).last_polled_issues[cached_issue.id].state == "ci-wait"
    end

    test "resume names stale blocker data even when the state label is unchanged" do
      name = Module.concat(__MODULE__, :ResumeStaleBlockers)
      pid = start_orchestrator(name)
      cached_issue = todo_issue("L11-BLOCKED")
      tracker_issue = %{cached_issue | blocked_by: [%{state: "todo"}]}
      memory_tracker!([tracker_issue])

      :sys.replace_state(pid, fn state ->
        %{state | last_polled_issues: %{cached_issue.id => cached_issue}, running: %{}, claimed: MapSet.new()}
      end)

      assert {:error, {:stale_tracker_state, :waiting_for_dependencies, %{cached_state: "todo", tracker_state: "todo", changed_fields: [:blockers]}}} =
               Orchestrator.resume_agent(name, cached_issue.identifier)
    end

    test "resume revalidates tracker state after clearing the pause override" do
      name = Module.concat(__MODULE__, :ResumeRelabelRace)
      pid = start_orchestrator(name)

      paused_issue =
        "L11-RACE"
        |> todo_issue()
        |> Map.put(:paused, true)
        |> Map.put(:labels, ["agent:todo", "agent:paused"])

      relabelled_issue = %{paused_issue | state: "merging", paused: false, labels: ["agent:merging"]}
      resume_refresh_tracker!([{:ok, [paused_issue]}, {:ok, [relabelled_issue]}])

      :sys.replace_state(pid, fn state ->
        %{state | last_polled_issues: %{paused_issue.id => paused_issue}, running: %{}, claimed: MapSet.new()}
      end)

      assert {:error, {:stale_tracker_state, {:tracker_state_not_resumable, "merging"}, %{cached_state: "todo", tracker_state: "merging", changed_fields: [:state]}}} =
               Orchestrator.resume_agent(name, paused_issue.identifier)

      assert_receive {:resume_refresh_remove_label, "L11-RACE", "agent:paused"}
      refute MapSet.member?(:sys.get_state(pid).claimed, paused_issue.id)
    end

    test "resume reports an authoritative missing ticket" do
      name = Module.concat(__MODULE__, :ResumeMissingTrackerIssue)
      pid = start_orchestrator(name)
      cached_issue = todo_issue("L11-MISSING")
      resume_refresh_tracker!([{:ok, []}])

      :sys.replace_state(pid, fn state ->
        %{state | last_polled_issues: %{cached_issue.id => cached_issue}, running: %{}, claimed: MapSet.new()}
      end)

      assert {:error, :tracker_issue_not_found} = Orchestrator.resume_agent(name, cached_issue.identifier)
      refute Map.has_key?(:sys.get_state(pid).last_polled_issues, cached_issue.id)
    end

    test "resume reports tracker refresh failures without mutating the cache" do
      name = Module.concat(__MODULE__, :ResumeTrackerFailure)
      pid = start_orchestrator(name)
      cached_issue = todo_issue("L11-TRACKER-DOWN")
      resume_refresh_tracker!([{:error, :timeout}])

      :sys.replace_state(pid, fn state ->
        %{state | last_polled_issues: %{cached_issue.id => cached_issue}, running: %{}, claimed: MapSet.new()}
      end)

      assert {:error, {:tracker_refresh_failed, :timeout}} =
               Orchestrator.resume_agent(name, cached_issue.identifier)

      assert :sys.get_state(pid).last_polled_issues[cached_issue.id] == cached_issue
    end
  end

  describe "poll recovery" do
    test "a stranded in-progress ticket is dispatched and reported with tracker truth" do
      previous_loadavg = Application.get_env(:aiur, :loadavg_source_override)
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)
      on_exit(fn -> restore_app_env(:loadavg_source_override, previous_loadavg) end)

      issue = %Issue{
        id: "L11-ORPHAN",
        identifier: "L11-ORPHAN",
        state: "in-progress",
        title: "Recover orphan"
      }

      memory_tracker!([issue])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["todo", "in-progress", "human-review", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        pre_warmed_sessions: 0
      )

      WorkflowStore.force_reload()

      name = Module.concat(__MODULE__, :RecoverOrphanedInProgress)
      pid = start_orchestrator(name)

      send(pid, :run_poll_cycle)
      state = :sys.get_state(pid, 15_000)

      assert MapSet.member?(state.claimed, issue.id)
      assert state.last_polled_issues[issue.id].state == "in-progress"

      assert %{running: [%{identifier: "L11-ORPHAN", state: "in-progress"}]} =
               Orchestrator.snapshot(name, 15_000)
    end
  end

  describe "drain semantics" do
    test "lowering the cap below active count reports draining and holds new dispatch" do
      name = Module.concat(__MODULE__, :Drain)
      pid = start_orchestrator(name)
      running = %{"a" => running_entry("a", "L12A", :working), "b" => running_entry("b", "L12B", :working)}
      :sys.replace_state(pid, &%{&1 | session_max_concurrent_agents: 3, running: running})

      assert {:ok, %{max: 1, draining?: true}} = Orchestrator.set_max_concurrent_agents(name, 1)
      state = :sys.get_state(pid)
      assert map_size(state.running) == 2
      refute Orchestrator.should_dispatch_issue_for_test(todo_issue("fresh-l12"), state)
    end
  end

  describe "max-duration bound" do
    test "an overrun active entry gets a cooperative pause, never a kill" do
      started_at = DateTime.add(DateTime.utc_now(), -120, :second)
      entry = Map.put(running_entry("l13", "L13", :working), :started_at, started_at)
      next = Orchestrator.apply_overrun_check_for_test(base_state(running: %{"l13" => entry}), 60)

      assert_receive {:pause_agent, _}, 2000
      assert get_in(next.running["l13"], [:control, :status]) == :paused
      assert next.running["l13"].paused_reason == :max_agent_duration
      assert next.running["l13"].pid == self()
    end

    test "a stale containment pause is logged and resumed" do
      name = Module.concat(__MODULE__, :ContainmentPause)
      pid = start_orchestrator(name)
      entry = running_entry("l16", "L16", :working)
      :sys.replace_state(pid, &%{&1 | running: %{"l16" => entry}, claimed: MapSet.new(["l16"])})

      log =
        capture_log(fn ->
          send(pid, {:worker_control_state, "l16", :paused, %{request_id: :containment}})
          assert_receive {:resume_agent, _}, 2_000
          # A synchronous system call queues after the worker message, so the
          # capture includes the log emitted by its handler under coverage load.
          _ = :sys.get_state(pid)
        end)

      resumed = :sys.get_state(pid).running["l16"]
      assert resumed.control.status == :working
      refute Map.has_key?(resumed, :paused_reason)
      assert log =~ "orchestrator.pause"
      assert log =~ "issue_identifier=L16"
      assert log =~ "cause=pause_containment"
    end

    test "a usage-limit worker pause is logged but not resumed" do
      name = Module.concat(__MODULE__, :UsageLimitPause)
      pid = start_orchestrator(name)
      entry = running_entry("l17", "L17", :working)
      :sys.replace_state(pid, &%{&1 | running: %{"l17" => entry}, claimed: MapSet.new(["l17"])})

      log =
        capture_log(fn ->
          send(pid, {:worker_control_state, "l17", :paused, %{kind: :usage_limit_exhausted}})
          assert :paused = get_in(:sys.get_state(pid, 15_000).running["l17"], [:control, :status])
        end)

      refute_receive {:resume_agent, _}, 100
      paused = :sys.get_state(pid).running["l17"]
      assert paused.paused_reason == :usage_limit_exhausted
      assert log =~ "orchestrator.pause"
      assert log =~ "issue_identifier=L17"
      assert log =~ "cause=usage_limit_exhausted"
    end

    test "an operator-attributed containment confirmation remains paused" do
      name = Module.concat(__MODULE__, :OperatorContainmentPause)
      pid = start_orchestrator(name)

      entry =
        "l18"
        |> running_entry("L18", :paused)
        |> Map.put(:paused_reason, :operator_pause)

      :sys.replace_state(pid, &%{&1 | running: %{"l18" => entry}, claimed: MapSet.new(["l18"])})

      send(pid, {:worker_control_state, "l18", :paused, %{request_id: :containment}})

      refute_receive {:resume_agent, _}, 100
      paused = :sys.get_state(pid).running["l18"]
      assert paused.control.status == :paused
      assert paused.paused_reason == :operator_pause
    end

    test "paused and deactivated entries are excluded from the overrun check" do
      started_at = DateTime.add(DateTime.utc_now(), -120, :second)

      running = %{
        "paused" => Map.put(running_entry("paused", "L14P", :paused), :started_at, started_at),
        "deactivated" => Map.put(running_entry("deactivated", "L14D", :deactivated), :started_at, started_at)
      }

      assert base_state(running: running) == Orchestrator.apply_overrun_check_for_test(base_state(running: running), 60)
      refute_receive {:pause_agent, _}, 100
    end

    test "duration-cap resume: operator resets the budget, automated resume preserves the overrun" do
      old_started = DateTime.add(DateTime.utc_now(), -300, :second)
      entry = running_entry("l15", "L15", :paused) |> Map.merge(%{started_at: old_started, paused_reason: :max_agent_duration})
      state = base_state(running: %{"l15" => entry})

      {{:ok, :resumed}, operator_state} = Orchestrator.resume_paused_issue_for_test(state, entry, true)
      {{:ok, :resumed}, auto_state} = Orchestrator.resume_paused_issue_for_test(state, entry, false)

      assert DateTime.diff(DateTime.utc_now(), operator_state.running["l15"].started_at, :second) in 0..2
      assert auto_state.running["l15"].started_at == old_started
      assert %DateTime{} = operator_state.running["l15"].last_codex_timestamp
      assert %DateTime{} = auto_state.running["l15"].last_codex_timestamp
    end
  end
end
