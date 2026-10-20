defmodule Aiur.Orchestrator.ControlCLI do
  @moduledoc false
  alias Aiur.{AgentChat, Orchestrator, PauseContainment}
  alias Aiur.ControlCLI.Reasons
  import Aiur.Orchestrator.ControlCLI.Resume, only: [resolve_queued_resumes: 1]
  import Aiur.ControlCLI.Protocol
  import Aiur.Orchestrator.ControlCLI.Output
  @status_timeout_ms 5_000
  # A deep orchestrator mailbox means `set max-agents` queues behind real contention; say so up front (#2137).
  @orchestrator_busy_mailbox_threshold 20
  # Absolute set of the concurrent-agent cap on a live node — `aiur set
  # max-agents N`. Positive validation lives in the CLI; the orchestrator
  # applies the session cap and reports whether active work is draining down.
  @spec set_max_agents(integer()) :: :ok
  def set_max_agents(n) do
    guarded("set max-agents", fn -> set_max_agents_result(n) end)
  end

  defp set_max_agents_result(n) when is_integer(n) and n > 0 do
    announce_if_orchestrator_busy()

    case Orchestrator.set_max_concurrent_agents(n) do
      {:ok, status} ->
        IO.puts("aiur: max-agents set to #{status.max} (#{max_agents_status_suffix(status)})")
        exit_marker(0)

      {:error, reason} ->
        control_error("aiur: failed to set max-agents (#{Reasons.format_reason(reason)}#{set_max_agents_timeout_detail(reason)})")
        exit_marker(control_query_exit_code(reason))
    end
  end

  defp set_max_agents_result(_n) do
    control_error("aiur: max-agents must be a positive integer")
    exit_marker(1)
  end

  # A write that times out waiting for the orchestrator must say what it was
  # waiting on, not just that the deadline elapsed (#2137): after a restart the
  # orchestrator is busy with its initial GitHub reconciliation poll, and a
  # `set max-agents` in that window can exhaust the 5s control call before the
  # poll drains. "orchestrator timed out" alone reads as host load; naming the
  # process state makes the wait legible and the retry response rational.
  defp set_max_agents_timeout_detail(:timeout), do: "; " <> orchestrator_liveness()
  defp set_max_agents_timeout_detail(_reason), do: ""

  # Report progress instead of appearing hung when the write is likely to wait:
  # a deep Orchestrator mailbox means it is wedged in poll work, and the write's
  # synchronous call will queue behind it. The note rides the RPC stdout the
  # launcher prints, so the operator sees why the command has not returned.
  defp announce_if_orchestrator_busy do
    with pid when is_pid(pid) <- Process.whereis(Orchestrator),
         {:message_queue_len, depth} when is_integer(depth) <- Process.info(pid, :message_queue_len),
         true <- depth > orchestrator_busy_mailbox_threshold() do
      IO.puts("aiur: waiting for the orchestrator to become available (it is busy; mailbox=#{depth})…")
    end

    :ok
  end

  defp orchestrator_busy_mailbox_threshold do
    Application.get_env(:aiur, :agent_control_cli_busy_mailbox_threshold, @orchestrator_busy_mailbox_threshold)
  end

  defp max_agents_status_suffix(%{active: active} = status) do
    paused = Map.get(status, :paused, 0)
    drain = if Map.get(status, :draining?) == true, do: ", draining", else: ""

    case paused do
      0 -> "#{active} active#{drain}"
      n -> "#{active} active, #{n} paused#{drain}"
    end
  end

  @spec pause(:all | [String.t()]) :: :ok
  def pause(targets), do: control(:pause, targets)
  @spec resume(:all | [String.t()]) :: :ok
  def resume(targets), do: control(:resume, targets)
  # Clear a named ticket's lifetime dispatch-budget latch so it can run again (#1453).
  @spec reset_budget([String.t()]) :: :ok
  def reset_budget(targets) when is_list(targets) do
    guarded("reset-budget", fn ->
      results =
        targets
        |> Enum.map(&to_string/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&reset_budget_one/1)

      exit_marker(results |> Enum.map(&control_result_exit_code/1) |> Enum.max(fn -> 0 end))
    end)
  end

  defp reset_budget_one(target) do
    case Orchestrator.reset_dispatch_budget(target) do
      {:ok, :reset} ->
        IO.puts("aiur: lifetime dispatch budget reset for ##{target}")
        :ok

      {:error, reason} ->
        print_failure(:reset_budget, %{identifier: target, issue_id: target}, reason)
        {:error, reason}
    end
  end

  # The global pause switch — `aiur pause` / `aiur resume` with no targets. A
  # single daemon-wide halt distinct from per-agent pause: it stops all
  # provisioning and holds every running agent, and unpause resumes only the
  # agents it held (never overriding an operator's per-agent pause).
  @spec pause_global() :: :ok
  def pause_global, do: set_global_pause(true)

  @spec resume_global() :: :ok
  def resume_global, do: set_global_pause(false)

  defp set_global_pause(on?) do
    verb = if on?, do: "pause", else: "resume"
    guarded(verb, fn -> set_global_pause_result(on?, verb) end)
  end

  defp set_global_pause_result(on?, verb) do
    source = if(on?, do: "CLI `pause`", else: "CLI `resume`")

    case set_global_pause_call(on?, source) do
      {:ok, %{globally_paused: paused}} ->
        IO.puts("aiur: global pause #{if paused, do: "ON — no agents will be provisioned", else: "OFF — new starts resume"}")

        exit_marker(0)

      {:error, reason} ->
        control_error("aiur: failed to #{verb} the daemon (#{Reasons.format_reason(reason)})")
        exit_marker(control_query_exit_code(reason))
    end
  end

  defp set_global_pause_call(on?, source) do
    Application.get_env(:aiur, :agent_control_cli_set_global_pause_fun, &Orchestrator.set_global_pause/2).(on?, source)
  end

  defp control(action, targets) when action in [:pause, :resume] do
    guarded(to_string(action), fn ->
      action
      |> control_status(targets, control_status_snapshot())
      |> exit_marker()
    end)
  end

  defp control_status(action, targets, statuses) when is_list(statuses) do
    case global_pause_status_for_control() do
      {:ok, %{globally_paused: true}} when action == :resume ->
        print_global_pause_control_error(action)
        1

      {:ok, _status} ->
        action
        |> select_targets(targets, statuses)
        |> control_selected(action, targets)

      {:error, :orchestrator_unavailable} ->
        print_global_pause_status_unavailable()
        1

      {:error, :timeout} ->
        print_orchestrator_status_error(:timeout)
        124
    end
  end

  # A targeted pause can still arm its locally-recorded containment group even
  # when the orchestrator is too congested to answer status. Preserve the
  # control-RPC result (and therefore the CLI's timeout/error contract); this
  # only gives the targeted AgentChat path a chance to arm its independent
  # fallback. `--all` remains status-driven because it has no safe target set.
  defp control_status(:pause, targets, error)
       when is_list(targets) and error in [:timeout, :unavailable] do
    Enum.each(targets, fn target ->
      _ = PauseContainment.arm_target(to_string(target))
    end)

    print_orchestrator_status_error(error)
    control_query_exit_code(error)
  end

  defp control_status(_action, _targets, error) when error in [:timeout, :unavailable] do
    print_orchestrator_status_error(error)
    control_query_exit_code(error)
  end

  defp global_pause_status_for_control do
    case Application.get_env(:aiur, :agent_control_cli_global_pause_status_fun) do
      nil -> fleet_global_pause_status(@status_timeout_ms)
      fun -> fun.()
    end
  end

  defp control_selected([], action, targets) do
    print_empty_selection(action, targets)
    1
  end

  defp control_selected(selected, action, _targets) do
    results =
      selected
      |> Enum.map(&control_one(action, &1))
      |> resolve_queued_resumes()

    results
    |> Enum.map(&control_result_exit_code/1)
    |> Enum.max(fn -> 0 end)
  end

  defp control_result_exit_code({:error, {:resume_unconfirmed, {:unknown, %{reason: {:status_unreadable, :timeout}}}}}), do: 124
  defp control_result_exit_code({:error, :timeout}), do: 124
  defp control_result_exit_code({:error, _reason}), do: 1
  defp control_result_exit_code(_result), do: 0

  # Control commands (`pause`/`resume`/`message`) select their targets from
  # fleet state the daemon already knows, so they must not queue behind the
  # Orchestrator mailbox the way `status`/`agents`/`watch` once did (#1837). A
  # blocked GitHub read on a held socket made `aiurdev resume <id>` time out
  # with "timed out while reading agent status" while `aiurdev status` answered
  # from the SnapshotStore read model in ~300ms (#2329). These reads serve from
  # that same read model, so a resume never depends on a busy or dead agent
  # process answering a status read.
  @spec control_status_snapshot() :: list() | :timeout | :unavailable
  def control_status_snapshot do
    case Application.get_env(:aiur, :agent_control_cli_status_fun) do
      nil -> fleet_status_snapshot(@status_timeout_ms)
      fun -> fun.()
    end
  end

  @spec confirmation_status_snapshot(non_neg_integer()) :: list() | :timeout | :unavailable
  def confirmation_status_snapshot(timeout_ms) do
    case Application.get_env(:aiur, :agent_control_cli_confirmation_status_fun) do
      nil -> fleet_status_snapshot(timeout_ms)
      fun -> fun.(Orchestrator, timeout_ms)
    end
  end

  defp fleet_status_snapshot(timeout_ms) do
    case control_fleet_view(timeout_ms, fleet_rows?: true) do
      {:ok, snapshot} ->
        case Map.get(snapshot, :statuses) do
          statuses when is_list(statuses) -> statuses
          _missing -> :unavailable
        end

      {:error, error} ->
        error
    end
  end

  defp fleet_global_pause_status(timeout_ms) do
    case control_fleet_view(timeout_ms, fleet_rows?: false) do
      {:ok, snapshot} ->
        case Map.get(snapshot, :global_pause) do
          %{globally_paused: paused} when is_boolean(paused) ->
            {:ok, %{globally_paused: paused}}

          _missing ->
            {:error, :orchestrator_unavailable}
        end

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, :unavailable} ->
        {:error, :orchestrator_unavailable}
    end
  end

  defp control_fleet_view(timeout_ms, opts) do
    case Orchestrator.fleet_view(Orchestrator, timeout_ms, opts) do
      {:ok, snapshot, _freshness} -> {:ok, snapshot}
      {:error, error} -> {:error, error}
    end
  end

  # The status row folds every registered, unpaused agent into `:running`.
  # Name the control state the agent was really in, so reactivating a
  # deactivated agent or restarting a completed one does not read as
  # "(was: running)".
  defp prior_state(%{state: :running, work_state: work_state})
       when work_state in [:deactivated, :completed, :sleeping, :error, :paused],
       do: work_state

  defp prior_state(%{state: state}), do: state

  defp select_targets(:pause, :all, statuses) do
    Enum.filter(statuses, &(&1.state in [:running, :paused]))
  end

  defp select_targets(:resume, :all, statuses) do
    Enum.filter(statuses, &(&1.state == :paused))
  end

  defp select_targets(_action, targets, statuses) when is_list(targets) do
    Enum.map(targets, fn target ->
      Enum.find(statuses, &target_matches?(&1, target)) ||
        %{identifier: target, issue_id: target, state: :missing}
    end)
  end

  defp control_one(:pause, %{state: :paused} = status) do
    IO.puts("aiur: already paused #{display_identifier(status)}")
    :ok
  end

  defp control_one(:pause, %{state: :running} = status) do
    canonical = canonical_identifier(status)

    case pause_agent(canonical) do
      {:ok, _request_id} ->
        IO.puts("aiur: paused #{display_identifier(status)} (was: running)")
        :ok

      {:error, reason} ->
        print_failure(:pause, status, reason)
        {:error, reason}
    end
  end

  defp control_one(:pause, status) do
    print_failure(:pause, status, :no_running_agent)
    {:error, :no_running_agent}
  end

  defp control_one(:resume, %{state: :paused} = status) do
    resume_selected(status)
  end

  defp control_one(:resume, %{state: :running, tracker_paused: true} = status) do
    resume_selected(status)
  end

  # A `:running` row is not proof that a worker is running. The row comes from
  # the published read model, which lags a pause: a pause is admitted before
  # the worker acknowledges it, and the snapshot can predate both. Answering
  # "already running" from the row left a paused worker stopped while the CLI
  # reported success (#2699). The Orchestrator owns the live registry, so it
  # decides: it resumes a pending or applied pause, and answers
  # `:already_running` only for a live `:working` worker.
  defp control_one(:resume, %{state: :running} = status) do
    resume_selected(status)
  end

  defp control_one(:resume, %{state: :idle} = status) do
    resume_selected(status)
  end

  defp control_one(:resume, status) do
    print_failure(:resume, status, :no_running_agent)
    {:error, :no_running_agent}
  end

  defp resume_selected(%{state: previous_state} = status) do
    canonical = canonical_identifier(status)

    case resume_agent(canonical) do
      # Only the paused-agent path is asynchronous: the orchestrator hands the
      # agent a resume control request and answers before the agent acts on it.
      # `:started` and `:reactivated` have already moved the issue into the
      # running set by the time they are returned, so they are claimable.
      # A receipt means the Orchestrator queued a resume for a paused agent or
      # one whose pause was still pending, even when the read model still
      # showed the row as `:running`. Confirm it the same way.
      {:ok, {:resumed, request_id}} ->
        {:queued_resume, status, request_id}

      {:ok, :resumed} when previous_state == :paused ->
        {:queued_resume, status, nil}

      {:ok, :already_running} ->
        IO.puts("aiur: already running #{display_identifier(status)}")
        :ok

      {:ok, :sleeping} ->
        IO.puts("aiur: already running #{display_identifier(status)} (sleeping: its stream closed while idle; it wakes on its next event)")
        :ok

      {:ok, result} when result in [:started, :resumed, :reactivated] ->
        IO.puts("aiur: #{result_verb(result)} #{display_identifier(status)} (was: #{prior_state(status)})")

        :ok

      {:error, reason} ->
        print_failure(:resume, status, reason)
        {:error, reason}
    end
  end

  defp pause_agent(identifier) do
    Application.get_env(:aiur, :agent_control_cli_pause_fun, &AgentChat.pause/1).(identifier)
  end

  defp resume_agent(identifier) do
    Application.get_env(:aiur, :agent_control_cli_resume_fun, &AgentChat.resume_with_receipt/1).(identifier)
  end

  defp result_verb(result),
    do: Map.fetch!(%{resumed: "resumed", started: "started", reactivated: "reactivated"}, result)
end
