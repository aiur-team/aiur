defmodule Aiur.Orchestrator.StatusCLI do
  @moduledoc false
  alias Aiur.Commands
  alias Aiur.Config
  alias Aiur.ControlCLI.CiWait
  alias Aiur.ExecutorAttention
  alias Aiur.GitHub.HoldPressure
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.CapacityBinding
  alias Aiur.Orchestrator.StatusObservation
  alias Aiur.SystemLoad
  alias Aiur.WorkflowStore.ReloadRejection
  import Aiur.ControlCLI.Protocol, only: [control_query_timeout: 3, exit_marker: 1, guarded: 2, report_control_query_failure: 3]
  alias Aiur.Orchestrator.StatusCLI.AgentsTable
  alias Aiur.Orchestrator.StatusCLI.Capacity
  alias Aiur.Orchestrator.StatusCLI.Diagnostics
  alias Aiur.Orchestrator.StatusCLI.StatusTable
  alias Aiur.Orchestrator.StatusCLI.Watch

  @status_timeout_ms 5_000
  # Leave room to render the daemon timeout before the 10-second watchdog edge (#1684).
  @agents_timeout_ms 6_000

  @spec status(keyword()) :: :ok
  def status(opts \\ []) do
    guarded("status", fn ->
      timeout_ms = control_query_timeout(opts, :status_timeout_ms, @status_timeout_ms)
      load_sample = Capacity.local_load_sample()

      # Read and show host pressure before touching the daemon. The fleet view
      # stays off the Orchestrator mailbox, while this local signal remains
      # available even if the daemon itself is overloaded or unreachable.
      Capacity.print_load_status(load_sample)

      with_fleet_view("status", opts, timeout_ms, fn snapshot, statuses ->
        print_status_report(statuses, snapshot, opts)
      end)
    end)
  end

  defp with_fleet_view(query, opts, timeout_ms, render) do
    case fleet_view(opts, timeout_ms, fleet_rows?: true) do
      {:ok, snapshot, freshness} -> render_fleet_view(query, opts, timeout_ms, {snapshot, freshness}, render)
      {:error, error} -> report_control_query_failure(error, query, timeout_ms)
    end
  end

  defp render_fleet_view(query, opts, timeout_ms, {snapshot, freshness}, render) do
    case fleet_statuses(snapshot) do
      {:ok, statuses} -> render_fleet_rows(query, opts, timeout_ms, {snapshot, freshness}, statuses, render)
      :error -> report_control_query_failure(:unavailable, query, timeout_ms)
    end
  end

  defp render_fleet_rows(query, opts, timeout_ms, {snapshot, freshness}, statuses, render) do
    case Diagnostics.print_global_pause_banner(global_pause_opts(opts, snapshot), timeout_ms) do
      :ok ->
        Aiur.AgentControlCLIFreshness.print(freshness, Map.get(snapshot, :global_pause))
        StatusObservation.print_groups(snapshot)
        render.(snapshot, statuses)

      {:error, error} ->
        report_control_query_failure(error, query, timeout_ms)
    end
  end

  # `status`, `agents` and `watch` read state the daemon already knows. Serving
  # them from the Orchestrator mailbox meant they queued behind whatever the
  # dispatch loop was doing — including a blocking GitHub read on a held socket,
  # which is what made both commands time out while `alerts` answered in ~300ms
  # (#1837). They read the snapshot read model instead, so a fetch in flight
  # cannot delay them.
  defp fleet_view(opts, timeout_ms, view_opts \\ []) do
    Keyword.get_lazy(opts, :fleet_view, fn -> Orchestrator.fleet_view(Orchestrator, timeout_ms, view_opts) end)
  end

  # A view with no rows in it is reported as unavailable, never rendered as an
  # empty fleet. "No agents" and "we could not read the agents" are different
  # facts, and this repo has already shipped the confusion once: `Active 0` and
  # every counter zero while nine agents were working.
  defp fleet_statuses(snapshot) do
    case Map.get(snapshot, :statuses) do
      statuses when is_list(statuses) -> {:ok, statuses}
      _missing -> :error
    end
  end

  defp global_pause_opts(opts, snapshot) do
    case Map.get(snapshot, :global_pause) do
      %{globally_paused: paused} = global_pause when is_boolean(paused) ->
        Keyword.put_new(opts, :global_pause_status, {:ok, global_pause})

      _other ->
        opts
    end
  end

  defp print_status_report(statuses, snapshot, opts) do
    Diagnostics.print_executor_listener_status()
    ExecutorAttention.CLI.print_wake_status()
    Commands.print_projection_status()
    Diagnostics.print_codeowners_trust()
    ReloadRejection.print_status()
    Aiur.Handoff.CLI.print_latest()
    Aiur.MergePolicyCLI.print()
    tracker_states = StatusTable.tracker_state_sets()
    # Count printed rows so hidden releases cannot inflate the headline (#1475).
    visible_statuses = Enum.filter(statuses, &StatusTable.visible_status_row?(&1, tracker_states))

    released_claims = Enum.count(visible_statuses, &(&1[:claim_released?] == true))

    automatic_reclaims =
      Enum.count(visible_statuses, &match?(%{reason: {:claim_released, _, retry_in_ms}} when is_integer(retry_in_ms), &1))

    StatusTable.print_status_table(visible_statuses)
    CiWait.print(snapshot)

    if released_claims > 0 do
      recovery = if automatic_reclaims == released_claims, do: "automatic re-claim pending", else: "operator recovery required for some claims"
      IO.puts("RELEASED CLAIMS #{released_claims} (#{recovery})")
    end

    SystemLoad.print_dispatch_sample(Map.get(snapshot, :capacity))
    Capacity.print_capacity_status(Map.get(snapshot, :capacity), Map.get(snapshot, :polling))
    print_polling_status(Map.get(snapshot, :polling))
    supervision_exit_code = Diagnostics.print_supervision_health()
    Diagnostics.print_ci_readiness()
    Diagnostics.print_build_gate_status()
    if Config.tracker_kind() == "github", do: HoldPressure.print_status()
    Diagnostics.print_prewarm_status()
    Watch.print_blocking_asks(opts)
    exit_marker(supervision_exit_code)
  end

  defp print_polling_status(polling) do
    print_last_dispatch_poll(polling)
    print_polling_backoff(polling)
    print_class_intervals(polling)
  end

  defp print_last_dispatch_poll(polling) do
    case CapacityBinding.dispatch_poll_status(polling) do
      %{freshness: :never_polled} -> IO.puts("POLL last dispatch: never polled")
      %{age_seconds: nil} -> IO.puts("POLL last dispatch: unavailable")
      %{age_seconds: age, freshness: freshness} -> IO.puts("POLL last dispatch: #{age}s ago (#{freshness})")
    end
  end

  defp print_polling_backoff(%{
         checking?: false,
         idle_backoff: %{active?: true, factor: factor},
         effective_interval_ms: effective_ms,
         poll_interval_ms: base_ms,
         next_poll_in_ms: next_ms
       }) do
    IO.puts(
      "POLL idle backoff active: interval=#{Capacity.poll_seconds(effective_ms)}s " <>
        "base=#{Capacity.poll_seconds(base_ms)}s factor=#{factor}x next=#{Capacity.poll_seconds(next_ms)}s"
    )
  end

  defp print_polling_backoff(_polling), do: :ok

  # Per-class cadence (#2309): an operator can see that planning is on-demand
  # (0s) while dispatch is at 2 minutes without reading config. Present only when
  # the snapshot carries `class_intervals`; the live orchestrator snapshot always
  # does, test fixtures may not.
  defp print_class_intervals(%{class_intervals: class_intervals}) when is_map(class_intervals) and map_size(class_intervals) > 0 do
    line =
      class_intervals
      |> Enum.sort_by(fn {class, _ms} -> class end)
      |> Enum.map_join(" ", fn {class, ms} -> "#{class}=#{Capacity.poll_seconds(ms)}s" end)

    IO.puts("POLL class intervals: #{line}")
  end

  defp print_class_intervals(_polling), do: :ok

  # Concise one-line-per-agent activity summary — the built-in, headless
  # equivalent of the dashboard / `aiur-status` log-tailing skill. Pulls the
  # orchestrator snapshot (richer than `status/0`: work-state + latest
  # activity) and prints state + what each agent is doing right now.
  @spec agents(keyword()) :: :ok
  def agents(opts \\ []) do
    guarded("agents", fn ->
      timeout_ms = control_query_timeout(opts, :snapshot_timeout_ms, @agents_timeout_ms)

      case fleet_view(opts, timeout_ms) do
        {:ok, %{running: running} = snapshot, freshness} when is_list(running) ->
          Aiur.AgentControlCLIFreshness.print(freshness, Map.get(snapshot, :global_pause))
          retrying = Map.get(snapshot, :retrying, [])
          idle = Map.get(snapshot, :idle, [])
          visible_idle = AgentsTable.visible_idle_rows(idle, Keyword.get(opts, :all, false))
          AgentsTable.print_agents_table(running ++ retrying ++ visible_idle)
          AgentsTable.print_idle_count(length(idle) - length(visible_idle))
          exit_marker(0)

        {:ok, _snapshot, _freshness} ->
          report_control_query_failure(:unavailable, "agents", timeout_ms)

        {:error, error} ->
          report_control_query_failure(error, "agents", timeout_ms)
      end
    end)
  end

  # `aiur watch` — the server-side status board. Compiles one row per active
  # agent (state · complexity · activity-age · what it's doing) plus an
  # actionable section (needs-attention alerts, stuck agents, PR-ready) entirely
  # from aiur's own state — the orchestrator status snapshot + the persisted
  # alert feed — with no GitHub round-trip. `mode: :full` prints every row;
  # `mode: :changes` (the default) prints only rows whose state-level signature
  # changed since the previous call, keeping the periodic Executor pull cheap.
  @spec watch(keyword()) :: :ok
  def watch(opts \\ []) do
    guarded("watch", fn ->
      timeout_ms = control_query_timeout(opts, :status_timeout_ms, @status_timeout_ms)

      with_fleet_view("watch", opts, timeout_ms, fn _snapshot, statuses ->
        Watch.print_watch_board(statuses, opts)
      end)
    end)
  end
end
