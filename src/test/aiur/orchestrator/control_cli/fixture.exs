defmodule Aiur.Orchestrator.ControlCLI.TestFixture do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks
  alias Aiur.AgentRunner.QueueDrain
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.SnapshotStore
  alias Aiur.TrackerIdentity
  # Tests that overwrite the shared workflow config must put it back: `Config`
  # re-reads the file on every call, so an unrestored write silently became the
  # next test's configuration (the capacity assertions flipped between the
  # fixture cap and the host-core default depending on seed).
  def restore_workflow_file_after_test do
    path = Aiur.Workflow.workflow_file_path()
    original = File.read!(path)
    on_exit(fn -> File.write!(path, original) end)
  end

  def running_entry(issue_id, identifier, status, pid \\ self()) do
    %{
      pid: pid,
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{id: issue_id, identifier: identifier, state: "In Progress", title: "Issue #{identifier}"},
      control: %{
        can_interrupt: true,
        safe_checkpoints: [:notification],
        status: status
      },
      session_id: "thread-#{identifier}",
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      started_at: DateTime.utc_now()
    }
  end

  # `running_entry/4` builds a *legacy* control entry (`can_interrupt` without
  # `generation`/`version`/`application_confirmation`), which resumes
  # synchronously inside the orchestrator call. Production agents carry the
  # modern shape below, where a resume is only *queued* for the agent and the
  # paused state clears when the agent reports back — the asynchronous path
  # #1634 was filed against.
  def modern_running_entry(issue_id, identifier, status, pid \\ self()) do
    issue_id
    |> running_entry(identifier, status, pid)
    |> put_in([:issue, Access.key(:tracker_identity)], %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "I_kwDO#{issue_id}",
      identifier: "44",
      reason: nil
    })
    |> Map.put(:control, %{
      can_interrupt: true,
      safe_checkpoints: [:notification],
      status: status,
      generation: 1,
      version: 1,
      application_confirmation: :confirmed
    })
  end

  # Stands in for the agent process: acknowledges the queued resume exactly the
  # way a live worker does, so the CLI can observe the paused state clearing.
  def acknowledging_agent(issue_id) do
    orchestrator = Process.whereis(Orchestrator)

    spawn_link(fn ->
      receive do
        {:resume_agent, request_id, generation} ->
          send(orchestrator, {
            :worker_control_state,
            issue_id,
            :working,
            %{request_id: request_id, generation: generation}
          })
      after
        5_000 -> :timeout
      end
    end)
  end

  def declining_agent(issue_id) do
    orchestrator = Process.whereis(Orchestrator)

    spawn_link(fn ->
      receive do
        {:resume_agent, request_id, generation} ->
          QueueDrain.apply_resume_control(
            %Issue{id: issue_id, identifier: "repo#44"},
            orchestrator,
            request_id,
            generation,
            release_pause: fn _identifier -> :ignored end
          )
      after
        5_000 -> :timeout
      end
    end)
  end

  def fence_snapshot_read_model do
    generation = SnapshotStore.begin_generation(Orchestrator)
    :ok = SnapshotStore.forget(Orchestrator)
    generation
  end

  def with_resume_confirm_timeout(timeout_ms, fun) do
    Application.put_env(:aiur, :agent_control_cli_resume_confirm_timeout_ms, timeout_ms)
    fun.()
  after
    Application.delete_env(:aiur, :agent_control_cli_resume_confirm_timeout_ms)
  end

  def with_message_confirm_timeout(timeout_ms, fun) do
    Application.put_env(:aiur, :agent_control_cli_message_confirm_timeout_ms, timeout_ms)
    fun.()
  after
    Application.delete_env(:aiur, :agent_control_cli_message_confirm_timeout_ms)
  end

  # Stub the delivery-status read `message` polls after a successful enqueue.
  def stub_message_delivery_status(result) do
    Application.put_env(:aiur, :agent_control_cli_message_status_fun, fn _request_id, _timeout ->
      result
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_message_status_fun) end)
  end

  def queued_issue(issue_id \\ "issue-queued") do
    %Issue{id: issue_id, identifier: "repo##{issue_id}", state: "In Progress", title: "Queued"}
  end

  # A running entry shaped for `watch` assertions: lets a test set the tracker
  # state, labels (for the complexity column), last activity timestamp (for age
  # / stuck detection) and last message (for the doing column).
  def watch_entry(issue_id, identifier, opts) do
    issue_id
    |> running_entry(identifier, Keyword.get(opts, :work_state, :working))
    |> update_in([:issue], fn issue ->
      %{issue | state: Keyword.get(opts, :state, "in-progress"), labels: Keyword.get(opts, :labels, [])}
    end)
    |> Map.put(:last_codex_timestamp, Keyword.get(opts, :last_codex_timestamp))
    |> Map.put(:last_codex_message, Keyword.get(opts, :last_codex_message))
  end

  def setup(context) do
    pid = Process.whereis(Orchestrator)
    original_state = orchestrator_state!(pid)

    original_health_status_fun = Application.get_env(:aiur, :supervision_health_status_fun)
    original_loadavg = Application.get_env(:aiur, :loadavg_source_override)

    Application.put_env(:aiur, :supervision_health_status_fun, fn -> {:ok, %{expected: 2, healthy: 2, missing: []}} end)
    Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1"} end)

    # Every control query reads the SnapshotStore read model before it asks the
    # Orchestrator, and that model is keyed by the shared registered name, so it
    # outlives whichever case or module published it. One retained projection
    # made the CLI ignore the state injected below and fail most of this file at
    # once ("no running agent", "(no active agents)"; main run 35281894177).
    # `forget/1` alone is not enough: a projection already queued in
    # SnapshotStore lands after it. A new generation fences that in-flight work,
    # and the Orchestrator adopts it so its own later publishes stay valid.
    snapshot_generation = fence_snapshot_read_model()

    :sys.replace_state(pid, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

      state =
        if context[:stale_dispatch_poll],
          do: %{state | last_dispatch_poll_at_ms: System.monotonic_time(:millisecond) - 3_600_000},
          else: state

      %{
        state
        | snapshot_generation: snapshot_generation,
          running: %{},
          last_polled_issues: %{},
          # Freeze the live poll for the duration of each case, the same way
          # OrchestratorStatusSupport does. These cases inject `running` and
          # `last_polled_issues` directly; a background poll against the
          # fixture's unreachable GitHub tracker would latch
          # `candidate_snapshot_fresh?: false` on the shared Orchestrator,
          # which blanks every injected idle row
          # (`StatusReport.visible_polled_issues/1`), and would flip
          # `snapshot_ready?`, publishing a fleet snapshot that later cases
          # then read back as last-known-good.
          tick_timer_ref: nil,
          tick_token: make_ref(),
          next_poll_due_at_ms: nil,
          poll_check_in_progress: false,
          poll_frozen: true,
          candidate_snapshot_fresh?: true,
          # Frozen polling cannot refresh an inherited timestamp during a long suite.
          last_dispatch_poll_at_ms: System.monotonic_time(:millisecond),
          snapshot_ready?: false,
          # Pin the pre-reconciliation baseline. The "orphaned claim" case below
          # asserts the `[waiting=orphaned_claim]` classification, which only
          # holds before startup reconciliation completes; the shared
          # Orchestrator may already have finished it (or a prior test may have
          # set it), so leaking the live value made that case order-dependent
          # (#2387 CI flake). The "stale claim" case pins `true` explicitly.
          startup_claim_reconciliation_complete?: false,
          session_max_concurrent_agents: nil,
          capacity_hold: nil,
          # Capacity fixtures start without dispatch holds from earlier polls.
          dispatch_hold: nil,
          dispatch_selection_hold: nil,
          dispatch_capacity_sample: %{load: :unavailable, load_threshold: nil, target: nil, schedulers: nil}
      }
    end)

    on_exit(fn ->
      if Process.alive?(pid) do
        # Drop anything this case published, then hand the Orchestrator its
        # prior state under the generation that is now active.
        restore_orchestrator_state(pid, original_state)
      end

      if original_health_status_fun do
        Application.put_env(:aiur, :supervision_health_status_fun, original_health_status_fun)
      else
        Application.delete_env(:aiur, :supervision_health_status_fun)
      end

      if original_loadavg do
        Application.put_env(:aiur, :loadavg_source_override, original_loadavg)
      else
        Application.delete_env(:aiur, :loadavg_source_override)
      end
    end)

    {:ok, orchestrator: pid}
  end

  def orchestrator_state!(pid, timeout \\ 5_000) do
    :sys.get_state(pid, timeout)
  catch
    :exit, reason ->
      info = Process.info(pid, [:current_function, :current_stacktrace, :message_queue_len, :messages, :status])
      flunk("Orchestrator fixture state read failed: #{inspect(reason)}; process=#{inspect(info)}")
  end

  def restore_orchestrator_state(pid, original_state) do
    snapshot_generation = fence_snapshot_read_model()

    :sys.replace_state(pid, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

      # Keep the shared test singleton dormant between cases, including
      # untagged poll work already queued by a resume during the case (#3007).
      %{original_state | snapshot_generation: snapshot_generation, poll_frozen: true, tick_timer_ref: nil, tick_token: make_ref(), next_poll_due_at_ms: nil, poll_check_in_progress: false}
    end)
  end
end
