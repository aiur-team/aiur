defmodule Aiur.AgentControlCLI do
  @moduledoc false
  import Aiur.Orchestrator.ControlCLI.Output, only: [display_identifier: 1, print_failure: 3]
  alias Aiur.Accounts.UsageReadings
  alias Aiur.ControlCLI.{CiWait, DispatchAccount}
  alias Aiur.ProviderMeters.CLI
  alias Aiur.Workspace.Ownership

  alias Aiur.{
    AccountsCLI,
    AlertFeed,
    AnalyticsCLI,
    BuildGate,
    BuildOrdersCLI,
    Commands,
    CommandsCLI,
    Config,
    ExecutorAttention,
    ExecutorBindings,
    ExecutorCommandCLI,
    ExecutorEvents,
    ExecutorListener,
    GitHubCostCLI,
    GitHubUsageCLI,
    Orchestrator,
    ProviderMeterProjection,
    RepoBase,
    SupervisionHealth,
    UnitsCLI
  }

  alias Aiur.Codex.EventHumanizer, as: CodexEventHumanizer
  alias Aiur.GitHub.{CiReadiness, CodeOwners, HoldPressure}
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Orchestrator.{CapacityBinding, DispatchPolicy, EnvelopeResume, OptimisticSlots, StatusObservation, StatusReason, WaitingReason}
  alias Aiur.SystemLoad
  alias Aiur.Webhooks.ModePresenter
  alias Aiur.WorkflowStore.ReloadRejection
  alias AiurWeb.OperatorControlCenter.UnitsPresentation
  import Aiur.EventHumanizerHelpers, only: [map_value: 2]

  import Aiur.ControlCLI.Protocol,
    only: [
      control_error: 1,
      control_query_timeout: 3,
      error_marker: 0,
      exit_marker: 1,
      guarded: 2,
      report_control_query_failure: 3
    ]

  @spec prepare_handoff(keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate prepare_handoff(opts \\ []), to: Aiur.Handoff, as: :prepare
  @status_timeout_ms 5_000
  # Leave room to render the daemon timeout before the 10-second watchdog edge (#1684).
  @agents_timeout_ms 6_000
  # RepoBase phases that mean the warm base is still becoming dispatchable.
  # Anything else with prewarm enabled — :ready
  # (normal), {:error, _} (fail-open cold clone), :idle — is not a "warming"
  # state and is handled separately.
  @prewarm_warming_phases [:cloning, :fetching, :building, :checking]

  # `aiur watch` remembers the last board it reported (per-row signature) in a node-local persistent term so
  # `--changes` can print only state-level deltas across one-shot RPC invocations. Updated at Executor cadence
  # (minutes), so the persistent_term churn is negligible.
  @watch_baseline_key {__MODULE__, :watch_baseline}
  @watch_stuck_after_seconds 600

  @spec status(keyword()) :: :ok
  def status(opts \\ []) do
    guarded("status", fn ->
      timeout_ms = control_query_timeout(opts, :status_timeout_ms, @status_timeout_ms)
      load_sample = local_load_sample()

      # Read and show host pressure before touching the daemon. The fleet view
      # stays off the Orchestrator mailbox, while this local signal remains
      # available even if the daemon itself is overloaded or unreachable.
      print_load_status(load_sample)

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
    case print_global_pause_banner(global_pause_opts(opts, snapshot), timeout_ms) do
      :ok ->
        print_snapshot_freshness(freshness)
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

  defp print_snapshot_freshness(%{status: :stale} = freshness) do
    IO.puts(
      "STALE FLEET VIEW — showing the last-known-good snapshot, #{UnitsPresentation.age_label(Map.get(freshness, :age_seconds))} old" <>
        stale_snapshot_reason(Map.get(freshness, :reason))
    )
  end

  defp print_snapshot_freshness(freshness), do: IO.puts("FLEET SNAPSHOT " <> StatusObservation.label(freshness))

  defp stale_snapshot_reason(:snapshot_timeout), do: " (the orchestrator is busy)"
  defp stale_snapshot_reason(:snapshot_stalled), do: " (the orchestrator has stopped publishing)"
  defp stale_snapshot_reason(:orchestrator_unavailable), do: " (the orchestrator is unavailable)"
  defp stale_snapshot_reason(_reason), do: ""

  @spec main_watch_state() :: map()
  defdelegate main_watch_state(), to: Aiur.MainWatch, as: :state
  @spec main_watch_inherited?(String.t(), String.t()) :: :inherited | :not_inherited | :unknown
  defdelegate main_watch_inherited?(check, merge_base), to: Aiur.MainWatch, as: :inherited?

  defp print_status_report(statuses, snapshot, opts) do
    print_executor_listener_status()
    ExecutorAttention.CLI.print_wake_status()
    Commands.print_projection_status()
    print_codeowners_trust()
    ReloadRejection.print_status()
    Aiur.MergePolicyCLI.print()
    tracker_states = tracker_state_sets()

    # Count printed rows so hidden releases cannot inflate the headline (#1475).
    visible_statuses = Enum.filter(statuses, &visible_status_row?(&1, tracker_states))

    released_claims = Enum.count(visible_statuses, &(&1[:claim_released?] == true))

    automatic_reclaims =
      Enum.count(visible_statuses, &match?(%{reason: {:claim_released, _, retry_in_ms}} when is_integer(retry_in_ms), &1))

    print_status_table(visible_statuses)
    CiWait.print(snapshot)

    if released_claims > 0 do
      recovery = if automatic_reclaims == released_claims, do: "automatic re-claim pending", else: "operator recovery required for some claims"
      IO.puts("RELEASED CLAIMS #{released_claims} (#{recovery})")
    end

    SystemLoad.print_dispatch_sample(Map.get(snapshot, :capacity))
    print_capacity_status(Map.get(snapshot, :capacity), Map.get(snapshot, :polling))
    print_polling_status(Map.get(snapshot, :polling))
    supervision_exit_code = print_supervision_health()
    print_ci_readiness()
    print_build_gate_status()
    if Config.tracker_kind() == "github", do: HoldPressure.print_status()
    print_prewarm_status()
    print_blocking_asks(opts)
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
      "POLL idle backoff active: interval=#{poll_seconds(effective_ms)}s " <>
        "base=#{poll_seconds(base_ms)}s factor=#{factor}x next=#{poll_seconds(next_ms)}s"
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
      |> Enum.map_join(" ", fn {class, ms} -> "#{class}=#{poll_seconds(ms)}s" end)

    IO.puts("POLL class intervals: #{line}")
  end

  defp print_class_intervals(_polling), do: :ok

  defp poll_seconds(milliseconds) when is_integer(milliseconds) and milliseconds >= 0,
    do: div(milliseconds, 1_000)

  defp poll_seconds(_milliseconds), do: 0

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
          print_snapshot_freshness(freshness)
          print_agents_table(running ++ Map.get(snapshot, :retrying, []) ++ Map.get(snapshot, :idle, []))
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
        print_watch_board(statuses, opts)
      end)
    end)
  end

  defp print_watch_board(statuses, opts) do
    print_prewarm_status()

    tracker_states = tracker_state_sets()

    rows =
      statuses
      |> Enum.filter(&visible_status_row?(&1, tracker_states))
      |> Enum.map(&watch_row/1)
      |> Enum.sort_by(& &1.sort_key)

    alerts = latest_attention_alerts(opts)
    blocking_asks = blocking_asks(opts)
    mode = Keyword.get(opts, :mode, :changes)
    {changed, removed} = update_watch_baseline(rows)
    render_watch(rows, alerts, blocking_asks, mode, changed, removed)
    exit_marker(0)
  end

  @spec alerts(keyword()) :: :ok
  def alerts(opts \\ []) do
    guarded("alerts", fn -> opts |> Aiur.AlertsCLI.run() |> exit_marker() end)
  end

  @spec commands(keyword()) :: :ok
  def commands(opts \\ []) do
    guarded("commands", fn -> CommandsCLI.run(opts) |> exit_marker() end)
  end

  @spec executor_answer(keyword()) :: :ok
  def executor_answer(opts) when is_list(opts) do
    guarded("executor-answer", fn -> opts |> ExecutorCommandCLI.answer(error_fun: &control_error/1) |> exit_marker() end)
  end

  @spec executor_escalate(keyword()) :: :ok
  def executor_escalate(opts) when is_list(opts) do
    guarded("executor-escalate", fn -> opts |> ExecutorCommandCLI.escalate(error_fun: &control_error/1) |> exit_marker() end)
  end

  @spec executor_moot(keyword()) :: :ok
  def executor_moot(opts) when is_list(opts) do
    guarded("executor-moot", fn -> opts |> ExecutorCommandCLI.moot(error_fun: &control_error/1) |> exit_marker() end)
  end

  @spec units(keyword()) :: :ok
  def units(opts \\ []), do: UnitsCLI.run(opts) |> exit_marker()

  @spec feature(keyword()) :: :ok
  def feature(opts \\ []), do: guarded("feature", fn -> opts |> Keyword.put(:error_fun, &control_error/1) |> Aiur.FeatureCLI.run() |> exit_marker() end)

  @spec epic(keyword()) :: :ok
  def epic(opts \\ []), do: guarded("epic", fn -> opts |> Keyword.put(:error_fun, &control_error/1) |> Aiur.EpicCLI.run() |> exit_marker() end)

  @spec build_orders(keyword()) :: :ok
  def build_orders(opts \\ []), do: guarded("build-orders", fn -> opts |> Keyword.put(:error_fun, &control_error/1) |> BuildOrdersCLI.run() |> exit_marker() end)

  @spec queue(keyword()) :: :ok
  def queue(opts \\ []), do: guarded("queue", fn -> opts |> Keyword.put(:error_fun, &control_error/1) |> Aiur.BuildQueueCLI.run() |> exit_marker() end)

  @spec analytics(keyword()) :: :ok
  def analytics(opts \\ []), do: guarded("analytics", fn -> AnalyticsCLI.run(opts) |> exit_marker() end)

  @spec github_cost(keyword()) :: :ok
  def github_cost(opts \\ []), do: guarded("github-cost", fn -> opts |> Keyword.put(:error_fun, &control_error/1) |> GitHubCostCLI.run() |> exit_marker() end)

  @spec experiments(keyword()) :: :ok
  def experiments(opts \\ []), do: guarded("experiments", fn -> opts |> Keyword.put(:error_fun, &control_error/1) |> Aiur.ExperimentsCLI.run() |> exit_marker() end)

  @spec capabilities(keyword()) :: :ok
  def capabilities(opts \\ []), do: guarded("capabilities", fn -> Aiur.CapabilitiesCLI.run(opts) |> exit_marker() end)

  @spec github_usage(keyword()) :: :ok
  def github_usage(opts \\ []), do: guarded("github-usage", fn -> GitHubUsageCLI.run(opts) |> exit_marker() end)

  defdelegate executor_emit(topic, payload_json), to: ExecutorAttention.CLI
  defdelegate executor_subscribe(topic), to: ExecutorAttention.CLI
  defdelegate executor_unsubscribe(topic), to: ExecutorAttention.CLI
  defdelegate executor_subscriptions(), to: ExecutorAttention.CLI
  defdelegate executor_listen(), to: ExecutorAttention.CLI
  defdelegate executor_listen(opts), to: ExecutorAttention.CLI
  defdelegate executor_wait(), to: ExecutorAttention.CLI
  defdelegate executor_wait(opts), to: ExecutorAttention.CLI
  defdelegate executor_fast_forward(wake_id), to: ExecutorAttention.CLI
  defdelegate executor_fast_forward(wake_id, opts), to: ExecutorAttention.CLI
  defdelegate executor_roster(), to: ExecutorAttention.CLI
  defdelegate executor_roster(opts), to: ExecutorAttention.CLI
  defdelegate executor_claim(), to: ExecutorAttention.CLI
  defdelegate executor_claim(opts), to: ExecutorAttention.CLI
  defdelegate executor_release(), to: ExecutorAttention.CLI
  defdelegate executor_release(opts), to: ExecutorAttention.CLI
  defdelegate executor_revoke(owner_id), to: ExecutorAttention.CLI
  defdelegate executor_revoke(owner_id, opts), to: ExecutorAttention.CLI

  @spec executor_listen_validate(String.t()) :: no_return()
  def executor_listen_validate(topic) do
    case ExecutorEvents.validate_binding_topic(topic) do
      :ok ->
        exit_marker(0)

      {:error, reason} ->
        IO.puts(error_marker() <> "aiur: listen topic rejected (#{inspect(reason)}); allowed bindings: #{Enum.join(ExecutorBindings.patterns(), ", ")}")
        exit_marker(64)
    end
  end

  @spec todo([String.t()], keyword()) :: 0 | 1
  defdelegate todo(issue_ids, opts \\ []), to: Aiur.Orchestrator.TodoCLI

  @spec reset_budget([String.t()]) :: :ok
  defdelegate reset_budget(targets), to: Aiur.Orchestrator.ControlCLI
  @spec pause_global() :: :ok
  defdelegate pause_global(), to: Aiur.Orchestrator.ControlCLI
  @spec resume_global() :: :ok
  defdelegate resume_global(), to: Aiur.Orchestrator.ControlCLI
  @spec set_max_agents(integer()) :: :ok
  defdelegate set_max_agents(n), to: Aiur.Orchestrator.ControlCLI
  @spec message(String.t(), String.t(), String.t() | nil) :: :ok
  defdelegate message(issue, text, message_id \\ nil), to: Aiur.Orchestrator.ControlCLI.Message

  @spec pause(:all | [String.t()]) :: :ok
  defdelegate pause(targets), to: Aiur.Orchestrator.ControlCLI

  @spec resume(:all | [String.t()]) :: :ok
  defdelegate resume(targets), to: Aiur.Orchestrator.ControlCLI
  @doc "Parks paused tickets without changing their workflow state."
  @spec park([String.t()]) :: :ok
  defdelegate park(targets), to: Aiur.ControlCLI.Park, as: :run

  @doc """
  Releases one workspace ownership generation after the daemon verifies
  independent local provider-exit proof. The caller must name the generation
  shown by status so a stale recovery command cannot release a replacement.
  """
  @spec recover_workspace(String.t(), pos_integer()) :: :ok
  def recover_workspace(ticket, generation) when is_binary(ticket) and is_integer(generation) and generation > 0 do
    guarded("workspace-recover", fn ->
      ticket_key = workspace_recovery_ticket_key(ticket)
      result = Ownership.release_if_held_with_exit_proof(ticket_key, generation)
      status = %{identifier: ticket, issue_id: ticket}

      report_workspace_recovery(result, ticket, generation, status)
    end)
  end

  defp report_workspace_recovery(:ok, ticket, generation, _status) do
    IO.puts("aiur: released workspace hold for #{ticket} generation #{generation}")
    exit_marker(0)
  end

  defp report_workspace_recovery({:error, {:audit_write_failed, reason}}, _ticket, _generation, _status) do
    IO.puts("__AIUR_CONTROL_ERROR__:aiur: workspace recovery was not performed because its durable audit write failed (#{inspect(reason)})")
    exit_marker(1)
  end

  defp report_workspace_recovery(result, _ticket, _generation, status) do
    reason = if result == :not_found, do: :not_found, else: recovery_failure_reason(result)
    print_failure(:workspace_recover, status, reason)
    exit_marker(1)
  end

  defp recovery_failure_reason(:not_held_for_reaping), do: :not_held_for_reaping
  defp recovery_failure_reason({:error, reason}), do: reason

  defp workspace_recovery_ticket_key(ticket) do
    case Regex.run(~r/^(?:[^#\/]+\/[^#\/]+#|#)(\d+)$/, ticket) do
      [_, issue_number] -> issue_number
      _ -> ticket
    end
  end

  defp print_status_table([]) do
    IO.puts("ISSUE STATE  TITLE")
    IO.puts("(no active agents)")
  end

  defp print_status_table(statuses) do
    IO.puts("ISSUE STATE   TITLE")

    Enum.each(statuses, fn status ->
      IO.puts([
        String.pad_trailing(display_identifier(status), 6),
        " ",
        String.pad_trailing(status_state_label(status), 7),
        " ",
        to_string(status.title || ""),
        status_reason_suffix(status)
      ])
    end)
  end

  defp status_reason_suffix(status) do
    reason = status_reason_detail(status)

    details =
      [
        waiting_reason_detail(status),
        dispatch_decline_detail(status),
        pause_reason_detail(status),
        blocked_by_detail(status),
        last_failure_detail(status)
      ]
      |> Enum.reject(&is_nil/1)

    reason_suffix = if reason, do: " (#{reason})", else: ""
    details_suffix = if details == [], do: "", else: " [#{Enum.join(details, "; ")}]"
    reason_suffix <> details_suffix <> WaitingReason.render_wait(status) <> StatusObservation.row_label(status) <> DispatchAccount.suffix(status)
  end

  defp status_reason_detail(%{reason: reason}) when not is_nil(reason), do: StatusReason.render(reason)
  defp status_reason_detail(_status), do: nil

  defp status_state_label(%{work_state: work_state}) when work_state in [:starting, :retrying], do: to_string(work_state)
  defp status_state_label(status), do: to_string(status.state)

  defp last_failure_detail(%{last_failure_at: %DateTime{} = at}), do: "last_failure_at=#{DateTime.to_iso8601(at)}"
  defp last_failure_detail(_status), do: nil

  defp waiting_reason_detail(%{waiting_reason: reason}) when not is_nil(reason),
    do: "waiting=#{WaitingReason.render(reason)}"

  defp waiting_reason_detail(_status), do: nil

  defp dispatch_decline_detail(%{dispatch_decline_reason: reason}) when is_atom(reason) and not is_nil(reason),
    do: "dispatch_decline=#{reason}"

  defp dispatch_decline_detail(%{dispatch_decline_reason: reason}) when not is_nil(reason),
    do: "dispatch_decline=#{inspect(reason)}"

  defp dispatch_decline_detail(_status), do: nil

  defp pause_reason_detail(%{pause_reason: reason}) when not is_nil(reason),
    do: "pause_reason=#{reason}"

  defp pause_reason_detail(_status), do: nil

  defp blocked_by_detail(%{waiting_reason: :waiting_for_dependency, blocked_by: blockers})
       when is_list(blockers) do
    names =
      blockers
      |> Enum.map(
        &(Map.get(&1, :identifier) || Map.get(&1, "identifier") || Map.get(&1, :id) ||
            Map.get(&1, "id"))
      )
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)

    if names == [], do: "blocked_by=unknown", else: "blocked_by=#{Enum.join(names, ",")}"
  end

  defp blocked_by_detail(_status), do: nil

  # The binding signal comes from the daemon; the CLI may run on another host.
  defp print_capacity_status(
         %{occupied: occupied, max: max, effective: effective, configured: configured} = capacity,
         polling
       )
       when is_integer(occupied) and is_integer(max) and is_integer(effective) and
              is_integer(configured) do
    binding = capacity_binding(capacity, polling)
    resume = if is_integer(capacity[:resume_level]) and elem(binding, 0) != :envelope, do: "; #{EnvelopeResume.label(capacity)}", else: ""
    IO.puts("AGENTS #{occupied}/#{max} (binding: #{capacity_binding_label(binding)})#{resume}#{OptimisticSlots.label(capacity)}")
  end

  defp print_capacity_status(_capacity, _polling), do: :ok

  defp local_load_sample do
    threshold = Config.max_load_average()

    %{
      load: SystemLoad.avg1(),
      load_threshold: threshold,
      schedulers: System.schedulers_online()
    }
  rescue
    _error -> %{load: :unavailable, load_threshold: nil, schedulers: nil}
  end

  defp capacity_binding_label({:tracker_preflight, hold}), do: "tracker preflight, reason=#{hold.detail} held=#{hold.held_for_seconds}s"

  defp capacity_binding_label({:dispatch_selection, hold}),
    do: "dispatch selection, reasons=#{inspect(hold.reasons)} candidates=#{hold.candidates}" <> admission_sample_age(hold)

  defp capacity_binding_label({:stale_poll, %{age_seconds: age}}), do: "dispatch poll stale (#{age}s ago)"

  defp capacity_binding_label({:awaiting_dispatch, %{ceiling: ceiling}}), do: "awaiting dispatch; ceiling: #{ceiling}"
  defp capacity_binding_label({:config_cap, _detail}), do: "config max_concurrent_agents"
  defp capacity_binding_label({:envelope, %{} = detail}), do: EnvelopeResume.label(detail)
  defp capacity_binding_label({:envelope, detail}), do: "AIMD envelope, effective cap=#{detail}"
  defp capacity_binding_label({:paused_reservations, detail}), do: "paused reservations=#{detail}"

  defp capacity_binding_label({:ticket_supply, %{ceiling: ceiling}}),
    do: "ticket supply; ceiling: #{ceiling}"

  defp capacity_binding_label({:ticket_supply, _detail}), do: "ticket supply"
  defp capacity_binding_label({:session_cap, _detail}), do: "session max_concurrent_agents"

  # Every admission measurement is rendered with the age of the sample it came
  # from; otherwise old readings look current beside the live LOAD line (#2527).
  defp capacity_binding_label({:admission, hold}),
    do: admission_detail(hold) <> admission_sample_age(hold)

  defp capacity_binding_label({:none, %{ceiling: ceiling}}), do: "none; ceiling: #{ceiling}"
  defp capacity_binding_label({:none, _detail}), do: "none"

  # The status line may only blame "ticket supply" when the daemon recently
  # polled and found no work. Idle backoff active or a failed candidate fetch
  # both mean the fleet has not looked recently enough to see work that
  # appeared — and blaming ticket supply there is the false explanation #2138
  # is about. Say what is actually true instead, and keep the ceiling source
  # visible so a restart that dropped a live `set max-agents` reads as
  # config-sourced rather than as the operator's last command (#2138).
  #
  # An idle backoff is a designed state, not a fault, so the label says why the
  # daemon is waiting and which knob set the width; a bare "backed off, next
  # poll in 599s" against a 120s config reads as a bug (#2640).
  defp capacity_binding_label({:idle_backoff, %{ceiling: ceiling} = detail}),
    do: "idle backoff active (#{idle_backoff_cause(detail)}#{idle_backoff_countdown(detail)}; ceiling: #{ceiling})"

  defp capacity_binding_label({:idle_backoff, detail}),
    do: "idle backoff active (#{idle_backoff_cause(detail)}#{idle_backoff_countdown(detail)})"

  defp capacity_binding_label({:has_not_polled, %{ceiling: ceiling}}),
    do: "has not polled yet (ceiling: #{ceiling})"

  defp capacity_binding_label({:has_not_polled, _detail}), do: "has not polled yet"

  defp idle_backoff_cause(%{factor: factor}) when is_number(factor),
    do: "no dispatchable demand at last poll; polling.idle_widen_factor=#{factor}"

  defp idle_backoff_cause(_detail), do: "no dispatchable demand at last poll"

  defp idle_backoff_countdown(%{next_poll_in_ms: next_ms}) when is_integer(next_ms),
    do: ", next poll in #{poll_seconds(next_ms)}s"

  defp idle_backoff_countdown(_detail), do: ""

  defp admission_detail(%{signal: :cpu_pressure, measured: pressure, threshold: threshold}),
    do: "CPU PSI some avg60=#{pressure}% threshold=#{threshold}%"

  defp admission_detail(%{signal: :memory, measured: memory, threshold: threshold}),
    do: "free memory=#{memory}MB threshold=#{threshold}MB"

  defp admission_detail(%{
         signal: :load,
         measured: load,
         threshold: threshold,
         reclaimable_cpu_percent: reclaimable,
         reclaimable_cpu_threshold: reclaimable_threshold
       }),
       do:
         "load+cpu contention, load=#{load} threshold=#{threshold} " <>
           "reclaimable_cpu=#{reclaimable}% threshold=#{reclaimable_threshold}%"

  defp admission_detail(%{signal: :load, measured: load, threshold: threshold}),
    do: "load, load=#{load} threshold=#{threshold}"

  defp admission_detail(%{
         signal: :run_queue,
         measured: runnable,
         threshold: threshold,
         reclaimable_cpu_percent: reclaimable,
         reclaimable_cpu_threshold: reclaimable_threshold
       }),
       do:
         "run_queue+cpu contention, runnable=#{runnable} threshold=#{threshold} " <>
           "reclaimable_cpu=#{reclaimable}% threshold=#{reclaimable_threshold}%"

  defp admission_detail(%{signal: :run_queue, measured: runnable, threshold: threshold}),
    do: "run_queue, runnable=#{runnable} threshold=#{threshold}"

  defp admission_detail(%{signal: :github_quota, measured: measured}) do
    case github_quota_measurement(measured) do
      {:current, detail} -> "github_quota, #{detail}"
      {:stale, detail} -> "github_quota stale, #{detail}"
      :unavailable -> "github_quota, measurement unavailable"
    end
  end

  defp admission_detail(%{signal: :provider, detail: detail}) when is_binary(detail),
    do: "provider, #{detail}"

  defp admission_detail(%{signal: signal}), do: to_string(signal)
  defp admission_detail(_hold), do: "admission"

  # A hold carrying no stamp predates #2527 and gets no age clause: an invented
  # "0s" would be the very false reassurance this line exists to remove.
  defp admission_sample_age(%{stale_sample?: true} = hold), do: sample_age_clause(hold, " STALE")
  defp admission_sample_age(hold), do: sample_age_clause(hold, "")

  defp sample_age_clause(hold, suffix) do
    case CapacityBinding.sample_age_seconds(hold) do
      age when is_integer(age) -> " sampled=#{age}s ago#{suffix}"
      nil -> ""
    end
  end

  defp github_quota_measurement(%{resource: resource, remaining: remaining, limit: limit, observed_at: observed_at}) do
    if stale_github_quota_measurement?(observed_at) do
      {:stale, "last_resource=#{resource} last_remaining=#{remaining}/#{limit} last_measured_at=#{format_observed_at(observed_at)}"}
    else
      {:current, "resource=#{resource} remaining=#{remaining}/#{limit} measured_at=#{format_observed_at(observed_at)}"}
    end
  end

  defp github_quota_measurement(_measured), do: :unavailable

  # The authority probes once a minute. Two missed intervals make a retained
  # capacity verdict historical evidence, not a claim about the live quota.
  defp stale_github_quota_measurement?(%DateTime{} = observed_at),
    do: DateTime.diff(DateTime.utc_now(), observed_at, :second) > 120

  defp stale_github_quota_measurement?(observed_at) when is_binary(observed_at) do
    case DateTime.from_iso8601(observed_at) do
      {:ok, parsed, _offset} -> stale_github_quota_measurement?(parsed)
      _invalid -> true
    end
  end

  defp stale_github_quota_measurement?(_observed_at), do: true

  defp format_observed_at(%DateTime{} = observed_at), do: DateTime.to_iso8601(observed_at)
  defp format_observed_at(observed_at) when is_binary(observed_at), do: observed_at
  defp format_observed_at(_observed_at), do: "unknown"

  # The classification lives in `Aiur.Orchestrator.CapacityBinding` so the CLI
  # and the dashboards name the same constraint from the same rules. Only the
  # label text below is CLI-specific — it carries the full admission
  # measurement, which does not fit a KPI tile.
  defp capacity_binding(capacity, polling), do: CapacityBinding.binding(capacity, polling)

  # A LOCAL host-pressure reading, taken before the control RPC so the
  # saturation signal survives an RPC timeout (the timeout is most likely
  # precisely when the box is loaded). It is explicitly not a fleet decision:
  # the daemon may run on another host, with another config, and may not be
  # holding at all. So the line says "local host sample" and, when the local
  # reading is over the local threshold, explains that the daemon still needs a
  # short-window CPU sample before it can identify real contention.
  defp print_load_status(%{load: load, load_threshold: threshold, schedulers: schedulers})
       when is_number(load) and is_number(threshold) and is_integer(schedulers) and schedulers > 0 do
    # The bare threshold check, deliberately: this line reports whether the
    # LOCAL sample is over the local ceiling. It must not call the admission
    # reason, which needs the daemon's short-window CPU measurement and
    # dispatches without one (#2089).
    suffix =
      case DispatchPolicy.load_gate(load, threshold, schedulers) do
        :hold ->
          " (local host sample; over fallback load threshold, PSI governs dispatch when available)"

        :dispatch ->
          " (local host sample)"
      end

    IO.puts("LOAD (local fallback diagnostic) #{load} threshold=#{threshold * schedulers} schedulers=#{schedulers}#{suffix}")
  end

  defp print_load_status(_capacity), do: :ok

  @doc """
  Print registry provider headroom from the daemon-owned meter projection.

  Every value carries the age of the observation, because meters are observed
  from live agent sessions: a number with no age cannot be told apart from a
  current one. A provider never observed prints as unknown, never as zero.

  Per-repo event delivery mode prints alongside the meters, because the two
  answer the same operator question — where is my quota going. A repo in
  polling mode always says *why*: never configured, configured but never
  delivered, or degraded after going silent. Repos with no webhooks anywhere
  print nothing extra, so this section only appears once it has something to
  say.
  """
  @spec usage(GenServer.server(), keyword()) :: :ok
  def usage(server \\ ProviderMeterProjection, opts \\ []) do
    guarded("usage", fn ->
      server
      |> ProviderMeterProjection.snapshot()
      |> Enum.sort_by(fn {provider, _view} -> provider end)
      |> Enum.each(&CLI.print/1)

      opts
      |> Keyword.get_lazy(:delivery_modes, fn -> ModePresenter.rows() end)
      |> print_delivery_modes()

      exit_marker(0)
    end)
  end

  @doc false
  @spec accounts(boolean(), String.t() | nil) :: :ok
  def accounts(json, harness \\ nil) do
    guarded("accounts", fn ->
      AccountsCLI.accounts(json, harness, &UsageReadings.snapshot("claude", &1))
      exit_marker(0)
    end)
  end

  defp print_delivery_modes([]), do: :ok

  defp print_delivery_modes(rows) do
    IO.puts("")

    Enum.each(
      rows,
      &IO.puts("events  #{&1.repo}  #{&1.mode_label}  last delivery #{&1.last_delivery_label}#{polling_reason_suffix(&1)}")
    )
  end

  defp polling_reason_suffix(%{reason_label: nil}), do: ""
  defp polling_reason_suffix(%{reason_label: label}), do: "  (#{label})"

  @spec usage_bar(number()) :: String.t()
  defdelegate usage_bar(percent), to: Aiur.ProviderMeters.CLI

  # Surface the global pause switch above the status table so an operator sees
  # at a glance that the whole daemon is halted (silent otherwise).
  defp print_global_pause_banner(opts, timeout_ms) do
    result =
      Keyword.get_lazy(opts, :global_pause_status, fn ->
        Orchestrator.global_pause_status(Orchestrator, timeout_ms)
      end)

    case result do
      {:ok, %{globally_paused: true, paused_at: paused_at, source: source}} ->
        provenance =
          [format_pause_source(source), format_pause_time(paused_at)]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(", ")

        suffix = if provenance == "", do: "", else: " (#{provenance})"

        IO.puts("GLOBALLY PAUSED#{suffix} — no agents will be provisioned (run `aiur resume` to lift)")

      {:ok, _} ->
        :ok

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, :orchestrator_unavailable} ->
        {:error, :unavailable}
    end
  end

  defp format_pause_source(source) when is_binary(source) and source != "", do: "set by #{source}"
  defp format_pause_source(_), do: nil

  defp format_pause_time(%DateTime{} = paused_at), do: "at #{DateTime.to_iso8601(paused_at)}"
  defp format_pause_time(_), do: nil

  # Surface whether the daemon-resident Executor listener is currently
  # listening. The listener is now armed on every run, so absence no longer
  # means "no Executor was intended" — it means the recording path is broken and
  # this run is losing its wake stream. The check reflects the live Exchange
  # binding, not "was started once".
  defp print_executor_listener_status do
    bindings = Application.get_env(:aiur, :executor_listener_alive_fun, &ExecutorListener.bindings/0).()
    bindings = if is_list(bindings), do: bindings, else: if(bindings, do: ["executor.#"], else: [])
    defaults = Aiur.ExecutorBindings.patterns()
    bound = MapSet.new(bindings)
    missing = Enum.reject(defaults, &MapSet.member?(bound, &1))

    cond do
      bindings == [] ->
        IO.puts("LISTENER absent (FAULT: recording is armed on every run, so this means the wake path is broken; Commands and PR events are not being recorded)")

      missing == [] ->
        IO.puts("LISTENER present (#{length(defaults)} bindings: #{Enum.join(defaults, ", ")})")

      true ->
        IO.puts("LISTENER degraded (#{length(defaults) - length(missing)}/#{length(defaults)} bindings; MISSING: #{Enum.join(missing, ", ")})")
    end
  end

  defp print_codeowners_trust do
    snapshot =
      Application.get_env(:aiur, :agent_control_cli_trust_snapshot_fun, fn ->
        if Process.whereis(CodeOwners), do: CodeOwners.trust_snapshot(), else: nil
      end).()

    case snapshot do
      %{trusted: trusted, source: source} = snapshot when is_list(trusted) ->
        source = source |> to_string() |> String.downcase()
        path = snapshot |> Map.get(:path) |> trust_path()
        accounts = Enum.map_join(trusted, ", ", &"@#{&1}")
        suffix = if path, do: " path=#{path}", else: ""
        IO.puts("COMMENT TRUST source=#{source} trusted=[#{accounts}]#{suffix}#{CodeOwners.status_suffix(snapshot)}")

      _ ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp trust_path(path) when is_binary(path) do
    case Path.relative_to_cwd(path) do
      relative when relative != path -> relative
      _ -> path
    end
  end

  defp trust_path(_path), do: nil

  defp print_build_gate_status do
    case BuildGate.status() do
      %{
        enabled?: true,
        capacity: capacity,
        active: active,
        queued: queued,
        degraded?: true,
        issues: [issue | remaining]
      } = status ->
        suffix = if remaining == [], do: "", else: " (+#{length(remaining)} more)"

        IO.puts(
          "BUILD GATE DEGRADED #{active}/#{capacity} active, #{queued} queued; " <>
            "max_concurrent_builds=#{capacity}; reason=#{issue.reason} path=#{issue.path}#{suffix}; " <>
            "recovery=#{issue.recovery}"
        )

        print_build_gate_holders(Map.get(status, :holders, []))
        print_build_gate_timeouts(Map.get(status, :timeouts, []))

      %{enabled?: true, capacity: capacity, active: active, queued: queued} = status
      when active > 0 or queued > 0 ->
        holders = Map.get(status, :holders, [])
        retain_seconds = Map.get(status, :retain_seconds)

        # A slot whose command process group is gone is not doing work: render
        # it apart from genuinely-busy slots so `BUILD GATE n/n active` never
        # reads as a confident wrong number (#2349).
        leaked = Enum.count(holders, &(&1.kind == :slot and &1.command_alive? == false))

        retain_suffix =
          if is_integer(retain_seconds) do
            ", retain_seconds=#{retain_seconds}"
          else
            ""
          end

        line =
          if leaked > 0 do
            "BUILD GATE #{active - leaked}/#{capacity} active, #{leaked} held without a command, " <>
              "#{queued} queued (max_concurrent_builds=#{capacity}#{retain_suffix})"
          else
            "BUILD GATE #{active}/#{capacity} active, #{queued} queued (max_concurrent_builds=#{capacity}#{retain_suffix})"
          end

        IO.puts(line)
        print_build_gate_holders(holders)
        print_build_gate_timeouts(Map.get(status, :timeouts, []))

      _ ->
        :ok
    end
  end

  # Name every lease currently held or queued so an operator can tell a
  # correctly-busy gate from one pinned by a leaked process (#2116). The
  # metadata is advisory: a record that cannot be parsed still leaves the
  # `active`/`queued` summary intact.
  defp print_build_gate_holders(holders) do
    Enum.each(holders, &print_build_gate_holder/1)
  end

  defp print_build_gate_holder(%{kind: :slot} = holder) do
    identifiers = ["slot=#{Map.get(holder, :slot)}", "pid=#{Map.get(holder, :pid)}"]
    annotation = if Map.get(holder, :command_alive?) == false, do: " (command gone)", else: ""
    print_build_gate_line("HOLDER", identifiers, holder, "held", annotation)
  end

  defp print_build_gate_holder(%{kind: :queue} = holder) do
    print_build_gate_line("QUEUED", ["pid=#{Map.get(holder, :pid)}"], holder, "waiting")
  end

  defp print_build_gate_holder(_holder), do: :ok

  # A `slot-N.hold-timeout` marker means the detached holder released the lease
  # at the absolute max-hold cap (#2349). Surface it so `aiur status` shows a
  # slot that timed out as well as one that is merely still held.
  defp print_build_gate_timeouts(timeouts) do
    Enum.each(timeouts, fn timeout ->
      IO.puts(
        "BUILD GATE TIMEOUT slot=#{timeout.slot} command=#{inspect(timeout.command)} " <>
          "held=#{format_gate_hold(timeout.held_for_seconds)} reason=#{timeout.reason}"
      )
    end)
  end

  defp print_build_gate_line(kind, identifiers, holder, duration_label) do
    print_build_gate_line(kind, identifiers, holder, duration_label, "")
  end

  defp print_build_gate_line(kind, identifiers, holder, duration_label, annotation) do
    with pid when is_integer(pid) <- Map.get(holder, :pid),
         command when is_binary(command) <- Map.get(holder, :command) do
      IO.puts(
        "BUILD GATE #{kind} #{Enum.join(identifiers, " ")} command=#{inspect(command)} " <>
          "#{duration_label}=#{format_gate_hold(Map.get(holder, :held_for_seconds))}#{annotation}"
      )
    else
      _ -> :ok
    end
  end

  defp format_gate_hold(nil), do: "unknown"

  defp format_gate_hold(seconds) when is_integer(seconds) and seconds >= 3_600 do
    "#{div(seconds, 3_600)}h#{div(rem(seconds, 3_600), 60)}m"
  end

  defp format_gate_hold(seconds) when is_integer(seconds) and seconds >= 60 do
    "#{div(seconds, 60)}m#{rem(seconds, 60)}s"
  end

  defp format_gate_hold(seconds) when is_integer(seconds) and seconds >= 0, do: "#{seconds}s"
  defp format_gate_hold(_seconds), do: "unknown"

  defp print_supervision_health do
    health_status =
      Application.get_env(:aiur, :supervision_health_status_fun, &SupervisionHealth.status/0)

    case health_status.() do
      {:ok, %{missing: []} = snapshot} ->
        IO.puts(SupervisionHealth.format(snapshot))
        0

      {:ok, snapshot} ->
        IO.puts(SupervisionHealth.format(snapshot))
        1

      {:error, :unavailable} ->
        IO.puts("SUPERVISION unavailable")
        1
    end
  end

  defp print_ci_readiness do
    if Config.tracker_kind() == "github" do
      case CiReadiness.cached_result() do
        :unavailable -> IO.puts("CI readiness: unavailable (no completed dispatcher assessment)")
        readiness -> IO.puts(CiReadiness.format(readiness))
      end
    end
  end

  # Surface the warm-base state so a gated fleet is distinguishable from an idle
  # one (#1404): with prewarm enabled, a warming base holds dispatch on every
  # poll tick and an errored base degrades to cold clones. A :ready base is the
  # normal steady state and prints nothing. No-op when prewarm is disabled or
  # RepoBase is not running.
  defp print_prewarm_status do
    if Config.prewarm_enabled?() do
      case prewarm_status_safe() do
        {phase, _base} when phase in @prewarm_warming_phases ->
          IO.puts("PREWARM prewarm: warming phase=#{phase} — dispatch held while the base build completes")

        {{:error, reason}, _base} ->
          IO.puts("PREWARM prewarm: unavailable reason=#{inspect(reason)} — dispatching via cold clone")

        _steady_or_unknown ->
          :ok
      end
    end
  end

  defp prewarm_status_safe do
    if Process.whereis(RepoBase), do: RepoBase.status(), else: {:idle, nil}
  rescue
    _ -> {:idle, nil}
  catch
    :exit, _ -> {:idle, nil}
  end

  defp visible_status_row?(%{work_state: :deactivated}, _tracker_states), do: false
  defp visible_status_row?(%{work_state: "deactivated"}, _tracker_states), do: false

  # A latched-out agent is idle but terminal: the lifetime dispatch budget is
  # exhausted and will not clear on its own (#1712). Keep the row visible even
  # when the tracker-state filters below would hide it, so `aiur status` shows
  # the state an operator has to act on.
  defp visible_status_row?(
         %{state: :idle, reason: {:latched, _lifetime, _maximum}},
         _tracker_states
       ),
       do: true

  # A released claim is an operator-actionable idle state, so it stays visible
  # even when the ticket is outside the active tracker states. It is NOT exempt
  # from the terminal filter: a claim released on a ticket that has since been
  # closed cannot be recovered, and showing it forever is a wrong count (#1475).
  defp visible_status_row?(%{state: :idle, reason: {:claim_released, _cause, _retry_in_ms}} = status, tracker_states) do
    not in_tracker_state_set?(Map.get(status, :tracker_state), tracker_states.terminal)
  end

  # An orphaned claim is the exact tracker/runtime contradiction status exists
  # to diagnose. Keep it visible even when a tracker's configured active-state
  # spelling differs from the normalized claim state in the retained row. A
  # post-reconciliation stale claim is the same contradiction and gets the same
  # treatment.
  defp visible_status_row?(%{state: :idle, reason: reason} = status, tracker_states)
       when reason in [:orphaned_claim, :stale_claim, :workspace_ownership_waiting, :workspace_retained] do
    not in_tracker_state_set?(Map.get(status, :tracker_state), tracker_states.terminal)
  end

  defp visible_status_row?(%{state: :idle, tracker_state: tracker_state}, tracker_states) do
    in_tracker_state_set?(tracker_state, tracker_states.active) and
      not in_tracker_state_set?(tracker_state, tracker_states.terminal)
  end

  defp visible_status_row?(%{tracker_state: tracker_state}, tracker_states) do
    not in_tracker_state_set?(tracker_state, tracker_states.terminal)
  end

  defp visible_status_row?(_status, _tracker_states), do: true

  defp in_tracker_state_set?(tracker_state, set) when is_binary(tracker_state) do
    MapSet.member?(set, normalized_tracker_state(tracker_state))
  end

  defp in_tracker_state_set?(_tracker_state, _set), do: false

  # Read the configured tracker states ONCE per command. Resolving them per row
  # meant two `Config.settings!/0` reads per agent, and each of those is a
  # `WorkflowStore` GenServer call — nine agents turned one status render into
  # eighteen chances to stall on a saturated daemon (#1684).
  defp tracker_state_sets do
    tracker = Config.settings!().tracker

    %{
      active: normalized_tracker_state_set(tracker.active_states),
      terminal: normalized_tracker_state_set(tracker.terminal_states)
    }
  end

  defp normalized_tracker_state_set(states) do
    states
    |> Enum.map(&normalized_tracker_state/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalized_tracker_state(state) when is_binary(state),
    do: String.downcase(String.trim(state))

  defp normalized_tracker_state(_state), do: ""

  @agents_header "ISSUE  STATE      RUNTIME  ACTIVITY"

  defp print_agents_table([]) do
    IO.puts(@agents_header)
    IO.puts("(no active agents)")
  end

  defp print_agents_table(running) do
    IO.puts(@agents_header)

    Enum.each(running, fn agent ->
      IO.puts([
        String.pad_trailing(display_identifier(agent), 6),
        " ",
        String.pad_trailing(agents_state_label(agent), 10),
        " ",
        String.pad_trailing(format_runtime(Map.get(agent, :runtime_seconds)), 8),
        " ",
        agents_activity(agent),
        if(agent[:repl_attach_command], do: " | " <> agent.repl_attach_command, else: ""),
        WaitingReason.render_wait(agent) <> StatusObservation.row_label(agent) <> DispatchAccount.suffix(agent)
      ])
    end)
  end

  # The STATE and ACTIVITY columns read the human wait from the row's derived
  # `waiting_reason` — the same fact `aiur status` prints as
  # `waiting=waiting_for_human` — never from the raw work state alone. A live
  # agent blocked on an open decision used to read `working` here while
  # `status` read `waiting_for_human` for the same ticket (#2698).
  defp agents_state_label(%{work_state: state}) when state in [:paused, "paused", :deactivated, "deactivated"],
    do: to_string(state)

  defp agents_state_label(agent) do
    if WaitingReason.waiting_for_human?(agent),
      do: "waiting",
      else: to_string(Map.get(agent, :work_state, :working))
  end

  defp agents_activity(agent) do
    if WaitingReason.waiting_for_human?(agent),
      do: "(#{WaitingReason.render(:waiting_for_human)}: #{human_wait_cause(agent)})",
      else: agent_activity(agent)
  end

  defp human_wait_cause(%{open_decision_count: count}) when is_integer(count) and count > 0,
    do: "#{count} open decision#{if count == 1, do: "", else: "s"}"

  defp human_wait_cause(_agent), do: "agent requested input"

  defp agent_activity(agent) do
    case Map.get(agent, :work_state, :working) do
      :retrying ->
        retry_activity(agent)

      :starting ->
        "(starting provider; no live turn yet)"

      paused when paused in [:paused, "paused"] ->
        paused_activity(agent)

      deactivated when deactivated in [:deactivated, "deactivated"] ->
        "(deactivated)"

      _ ->
        activity_values(agent)
        |> Enum.map(&activity_string/1)
        |> Enum.find("", &(&1 != ""))
        |> case do
          "" -> "(no activity yet)"
          text -> truncate(text, 80)
        end
    end
  end

  defp retry_activity(agent) do
    reason =
      case Map.get(agent, :error) do
        "startup failed: {:port_exit, " <> _ = error ->
          if String.match?(error, ~r/^startup failed: \{:port_exit, \d+\}$/), do: error, else: "previous worker failure"

        _ ->
          "previous worker failure"
      end

    time =
      case Map.get(agent, :last_failure_at) do
        %DateTime{} = at -> "; last failure #{DateTime.to_iso8601(at)}"
        _ -> ""
      end

    "(retrying: #{reason}#{time})"
  end

  defp activity_values(agent) do
    message = Map.get(agent, :last_codex_message)
    event = Map.get(agent, :last_codex_event)

    if structured_activity?(message) do
      [message, event]
    else
      [event, message]
    end
  end

  defp structured_activity?(%{message: message}) when is_map(message),
    do: structured_activity?(message)

  defp structured_activity?(message) when is_map(message) do
    message
    |> activity_payload()
    |> map_value(["method", :method])
    |> is_binary()
  end

  defp structured_activity?(_value), do: false

  defp activity_string(value) when is_binary(value), do: String.trim(value)
  defp activity_string(nil), do: ""

  defp activity_string(%{message: message}) when is_map(message) do
    activity_string(message)
  end

  defp activity_string(message) when is_map(message) do
    payload = activity_payload(message)

    case map_value(payload, ["method", :method]) do
      method when is_binary(method) ->
        method |> CodexEventHumanizer.humanize_method(payload) |> String.trim()

      _ ->
        message |> inspect(limit: 5, printable_limit: 120) |> String.trim()
    end
  end

  defp activity_string(value),
    do: value |> inspect(limit: 5, printable_limit: 120) |> String.trim()

  defp paused_activity(%{pause_reason: :label_override}), do: "(paused: label override)"
  defp paused_activity(%{pause_reason: "label_override"}), do: "(paused: label override)"
  defp paused_activity(_agent), do: "(paused)"

  defp truncate(text, max) do
    collapsed = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(collapsed) > max do
      String.slice(collapsed, 0, max - 1) <> "…"
    else
      collapsed
    end
  end

  defp format_runtime(seconds) when is_integer(seconds) and seconds >= 0 do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      true -> "#{div(seconds, 3600)}h#{rem(div(seconds, 60), 60)}m"
    end
  end

  defp format_runtime(_), do: "-"

  defp watch_row(status) do
    state = watch_state(status)
    age = activity_age_seconds(status)
    run_state = Map.get(status, :state)
    stuck? = run_state == :running and is_integer(age) and age >= @watch_stuck_after_seconds
    pr_ready? = state in ["human-review", "merging"]
    reason = Map.get(status, :reason)

    %{
      id: display_identifier(status),
      key: to_string(Map.get(status, :issue_id) || Map.get(status, :identifier) || display_identifier(status)),
      sort_key: watch_sort_key(status),
      state: state,
      complexity: Map.get(status, :complexity),
      age_seconds: age,
      stuck?: stuck?,
      pr_ready?: pr_ready?,
      doing: watch_activity(status),
      waiting: WaitingReason.render_wait(status),
      signature:
        {state, Map.get(status, :complexity), Map.get(status, :work_state, run_state), watch_reason_signature(reason), Map.take(status[:waiting] || %{}, [:reason, :owner, :cause]), stuck?, pr_ready?}
    }
  end

  defp watch_state(%{tracker_paused: true}), do: "paused"
  defp watch_state(%{tracker_paused: "true"}), do: "paused"
  defp watch_state(%{work_state: work_state}) when work_state in [:starting, :retrying], do: to_string(work_state)
  defp watch_state(status), do: to_string(status[:tracker_state] || status[:state] || "")

  defp watch_activity(%{tracker_paused: paused, reason: reason})
       when paused in [true, "true"] and not is_nil(reason),
       do: "(paused: #{StatusReason.render(reason)})"

  defp watch_activity(%{tracker_paused: true}), do: "(paused: label override)"
  defp watch_activity(%{tracker_paused: "true"}), do: "(paused: label override)"
  defp watch_activity(%{tracker_state: "ci-wait"}), do: "(waiting for CI)"
  defp watch_activity(%{state: "ci-wait"}), do: "(waiting for CI)"

  defp watch_activity(%{state: :idle, reason: reason}) when not is_nil(reason),
    do: "(idle: #{StatusReason.render(reason)})"

  defp watch_activity(%{state: :idle}), do: "(idle)"

  defp watch_activity(%{work_state: :retrying, reason: reason}) when not is_nil(reason),
    do: "(retrying: #{StatusReason.render(reason)})"

  defp watch_activity(%{state: :paused, reason: reason}) when not is_nil(reason),
    do: "(paused: #{StatusReason.render(reason)})"

  defp watch_activity(status), do: agent_activity(status)

  defp watch_reason_signature(nil), do: nil
  defp watch_reason_signature(reason), do: StatusReason.render(reason)

  defp watch_sort_key(status) do
    raw = to_string(Map.get(status, :issue_id) || Map.get(status, :identifier) || "")

    case Integer.parse(raw) do
      {n, _rest} -> {0, n, raw}
      :error -> {1, 0, raw}
    end
  end

  defp activity_age_seconds(%{last_codex_timestamp: %DateTime{} = dt}) do
    max(0, DateTime.diff(DateTime.utc_now(), dt))
  end

  defp activity_age_seconds(%{last_codex_timestamp: ts}) when is_binary(ts) and ts != "" do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> max(0, DateTime.diff(DateTime.utc_now(), dt))
      _invalid -> nil
    end
  end

  defp activity_age_seconds(_status), do: nil

  # The alert feed is append-only history; collapse to the most-recent
  # needs-attention alert per ticket so the actionable section stays one current
  # concern per agent rather than replaying the whole log.
  defp latest_attention_alerts(opts) do
    [needs_attention: true]
    |> Keyword.merge(Keyword.take(opts, [:roots, :log_roots, :ledger_paths]))
    |> AlertFeed.list()
    |> Enum.group_by(&Map.get(&1, "ticket"))
    |> Enum.map(fn {_ticket, alerts} -> List.last(alerts) end)
    |> Enum.sort_by(&to_string(Map.get(&1, "ticket")))
  end

  # Diff against the previously-reported board, keyed on the canonical issue id
  # (not the display string, which could collide across repos). Each baseline
  # entry keeps the row's state-level signature plus its display id so a removed
  # ticket can still be named after it has left the roster.
  defp update_watch_baseline(rows) do
    previous = :persistent_term.get(@watch_baseline_key, %{})
    current = Map.new(rows, &{&1.key, {&1.signature, &1.id}})
    :persistent_term.put(@watch_baseline_key, current)

    changed =
      for {key, {sig, _id}} <- current,
          baseline_signature(previous, key) != sig,
          into: MapSet.new(),
          do: key

    removed = for {key, {_sig, id}} <- previous, not Map.has_key?(current, key), do: id

    {changed, Enum.sort(removed)}
  end

  defp baseline_signature(baseline, key) do
    case Map.get(baseline, key) do
      {sig, _id} -> sig
      _ -> nil
    end
  end

  @watch_header "TICKET  STATE         CX  AGE     DOING"

  defp render_watch(rows, alerts, blocking_asks, mode, changed, removed) do
    rows
    |> watch_rows_for_mode(mode, changed)
    |> print_watch_table(mode)

    print_watch_actionable(rows, alerts, blocking_asks, removed)
  end

  defp watch_rows_for_mode(rows, :changes, changed) do
    Enum.filter(rows, &MapSet.member?(changed, &1.key))
  end

  defp watch_rows_for_mode(rows, _mode, _changed), do: rows

  defp print_watch_table([], :changes), do: IO.puts("(no changes)")

  defp print_watch_table([], _mode) do
    IO.puts(@watch_header)
    IO.puts("(no active agents)")
  end

  defp print_watch_table(rows, _mode) do
    IO.puts(@watch_header)
    Enum.each(rows, fn row -> IO.puts(watch_table_line(row)) end)
  end

  defp watch_table_line(row) do
    [
      String.pad_trailing(row.id, 7),
      " ",
      String.pad_trailing(truncate(row.state, 13), 13),
      " ",
      String.pad_trailing(format_complexity(row.complexity), 2),
      " ",
      String.pad_trailing(format_runtime(row.age_seconds), 7),
      " ",
      watch_doing(row),
      row.waiting
    ]
  end

  defp watch_doing(%{stuck?: true, doing: doing}), do: "⚠ stuck · " <> truncate(doing, 68)
  defp watch_doing(%{doing: doing}), do: truncate(doing, 80)

  defp format_complexity(n) when is_integer(n), do: to_string(n)
  defp format_complexity(_n), do: "-"

  defp print_watch_actionable(rows, alerts, blocking_asks, removed) do
    lines =
      watch_alert_lines(alerts) ++
        watch_ask_lines(blocking_asks) ++
        watch_stuck_lines(rows) ++
        watch_pr_ready_lines(rows) ++
        watch_removed_lines(removed)

    print_watch_actionable_lines(lines)
  end

  defp print_watch_actionable_lines([]), do: :ok

  defp print_watch_actionable_lines(lines) do
    IO.puts("")
    IO.puts("ACTIONABLE")
    Enum.each(lines, &IO.puts/1)
  end

  defp watch_alert_lines(alerts) do
    Enum.map(alerts, fn alert ->
      "! ##{Map.get(alert, "ticket")} · #{Map.get(alert, "name")} · #{Map.get(alert, "reason")}"
    end)
  end

  defp watch_ask_lines({:ok, asks}) do
    Enum.map(asks, fn ask ->
      "! BLOCKING ASK #{ask["id"]} · #{ask["urgency"]} · #{ask["created_at"]} · #{truncate(ask["title"], 56)}"
    end)
  end

  defp watch_ask_lines({:error, reason}),
    do: ["! BLOCKING ASKS UNAVAILABLE · #{format_ask_store_error(reason)}"]

  defp print_blocking_asks(opts) do
    case blocking_asks(opts) do
      {:ok, []} ->
        :ok

      {:ok, asks} ->
        IO.puts("OPERATOR ASKS (blocking)")

        Enum.each(asks, fn ask ->
          IO.puts("! #{ask["id"]} · #{ask["urgency"]} · from #{ask["created_by"]} at #{ask["created_at"]} · #{ask["title"]}")
        end)

      {:error, reason} ->
        IO.puts("OPERATOR ASKS (blocking) UNAVAILABLE")
        IO.puts("! #{format_ask_store_error(reason)}")
    end
  end

  defp blocking_asks(opts) do
    case Keyword.fetch(opts, :blocking_asks) do
      {:ok, asks} when is_list(asks) ->
        {:ok, asks}

      _ ->
        blocking_asks_for_configured_repo()
    end
  end

  defp blocking_asks_for_configured_repo do
    case GitHubConfig.repo() do
      repo when is_binary(repo) and repo != "" -> blocking_asks_for_repo(repo)
      _ -> {:ok, []}
    end
  end

  defp blocking_asks_for_repo(repo) do
    with {:ok, asks} <- Commands.open_asks(repo), do: {:ok, Enum.filter(asks, &(&1["blocking"] == true))}
  end

  defp format_ask_store_error({:invalid_ask_record, _path, line_number, reason}),
    do: "could not read durable ask record #{line_number}: #{inspect(reason)}"

  defp format_ask_store_error(_reason), do: "could not read the durable operator ask store"

  defp watch_stuck_lines(rows) do
    rows
    |> Enum.filter(& &1.stuck?)
    |> Enum.map(fn row ->
      "~ #{row.id} stuck · no activity for #{format_runtime(row.age_seconds)}"
    end)
  end

  defp watch_pr_ready_lines(rows) do
    rows
    |> Enum.filter(& &1.pr_ready?)
    |> Enum.map(fn row -> "> #{row.id} #{row.state} · needs review/merge" end)
  end

  defp watch_removed_lines(removed) do
    Enum.map(removed, fn id -> "- #{id} · left the board" end)
  end

  defp activity_payload(message) do
    case map_value(message, ["payload", :payload]) do
      payload when is_map(payload) -> payload
      _ -> message
    end
  end
end
