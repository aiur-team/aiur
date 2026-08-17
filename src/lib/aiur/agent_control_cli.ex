defmodule Aiur.AgentControlCLI do
  @moduledoc false

  alias Aiur.{
    AgentChat,
    AlertFeed,
    AnalyticsCLI,
    Asks,
    BuildGate,
    BuildOrdersCLI,
    CommandsCLI,
    Config,
    ExecutorCommandCLI,
    ExecutorEvents,
    ExecutorListener,
    ExecutorWakeInbox,
    GitHubCostCLI,
    Issue,
    Orchestrator,
    PauseContainment,
    ProviderMeterProjection,
    RepoBase,
    SupervisionHealth,
    UnitsCLI
  }

  alias Aiur.Codex.EventHumanizer, as: CodexEventHumanizer
  alias Aiur.GitHub.{CiReadiness, CodeOwners, StatePolicy}
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.Tracker, as: GitHubTracker
  alias Aiur.Orchestrator.{DispatchPolicy, StatusReason, WaitingReason}
  alias Aiur.SystemLoad
  alias Aiur.Webhooks.ModePresenter
  # One age shape wherever a stale surface appears — reuse #1814's renderer
  # rather than adding a second one for the CLI.
  alias AiurWeb.OperatorControlCenter.UnitsPresentation
  import Aiur.EventHumanizerHelpers, only: [map_value: 2]

  @exit_marker "__AIUR_CONTROL_EXIT__:"
  @error_marker "__AIUR_CONTROL_ERROR__:"
  @status_timeout_ms 5_000
  # Leave the launcher watchdog room to receive and render the daemon's explicit
  # timeout result instead of racing it at the shared 10-second edge. Eight
  # seconds was not enough: RPC BEAM startup costs ~2s, so a saturated snapshot
  # measured 10335ms and lost the race — the launcher killed it at 10s and the
  # operator got a truncated fleet listing plus exit 124 instead of one honest
  # "agents query timed out after 8s" line (#1684).
  @agents_timeout_ms 6_000

  # `{:ok, :resumed}` from the orchestrator means a resume control request was
  # *enqueued* for the agent, not that the agent left the paused state (see
  # `Aiur.Orchestrator.PauseResume.send_resume_control_message/3`). Printing
  # "resumed #44" at that point is a confident wrong outcome: in #1634 three
  # agents stayed paused while the CLI reported no failure at all. So observe
  # the agent's own control status leaving `:paused` before claiming it, and
  # report an unconfirmed request as a failure rather than as success.
  #
  # One invocation shares a single confirmation budget across every queued
  # resume, so `resume --all` over a large fleet still fits inside the
  # launcher's 10s control-RPC timeout.
  @resume_confirm_timeout_ms 4_000
  @resume_confirm_poll_ms 100

  # RepoBase phases that mean the warm base is still becoming dispatchable
  # (the gate holds new work). Anything else with prewarm enabled — :ready
  # (normal), {:error, _} (fail-open cold clone), :idle — is not a "warming"
  # state and is handled separately.
  @prewarm_warming_phases [:cloning, :fetching, :building, :checking]

  # `aiur watch` remembers the last board it reported (per-row signature) in a
  # node-local persistent term so `--changes` can print only state-level deltas
  # across one-shot RPC invocations. Updated at Executor cadence (minutes), so
  # the persistent_term churn is negligible.
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

  # The shared shape of every fleet-reading control query: read the view, say so
  # if it is stale, print the global-pause banner, then render.
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
    print_snapshot_freshness(freshness)

    case print_global_pause_banner(global_pause_opts(opts, snapshot), timeout_ms) do
      :ok -> render.(snapshot, statuses)
      {:error, error} -> report_control_query_failure(error, query, timeout_ms)
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

  # A stale fleet view that looks current is worse than the timeout it replaces.
  # When the read model is serving last-known-good data, say so and say how old,
  # in the shape #1814 established.
  defp print_snapshot_freshness(%{status: :stale} = freshness) do
    IO.puts(
      "STALE FLEET VIEW — showing the last-known-good snapshot, #{UnitsPresentation.age_label(Map.get(freshness, :age_seconds))} old" <>
        stale_snapshot_reason(Map.get(freshness, :reason))
    )
  end

  defp print_snapshot_freshness(_freshness), do: :ok

  defp stale_snapshot_reason(:snapshot_timeout), do: " (the orchestrator is busy)"
  defp stale_snapshot_reason(:snapshot_stalled), do: " (the orchestrator has stopped publishing)"
  defp stale_snapshot_reason(:orchestrator_unavailable), do: " (the orchestrator is unavailable)"
  defp stale_snapshot_reason(_reason), do: ""

  defp print_status_report(statuses, snapshot, opts) do
    print_executor_listener_status()
    print_codeowners_trust()

    tracker_states = tracker_state_sets()

    # Count from the rows that are actually printed. Counting the unfiltered
    # `statuses` let `RELEASED CLAIMS n` claim releases whose rows were hidden,
    # so the headline and the table disagreed (#1475).
    visible_statuses = Enum.filter(statuses, &visible_status_row?(&1, tracker_states))

    released_claims = Enum.count(visible_statuses, &(&1[:claim_released?] == true))

    automatic_reclaims =
      Enum.count(visible_statuses, &match?(%{reason: {:claim_released, _, retry_in_ms}} when is_integer(retry_in_ms), &1))

    print_status_table(visible_statuses)

    if released_claims > 0 do
      recovery = if automatic_reclaims == released_claims, do: "automatic re-claim pending", else: "operator recovery required for some claims"
      IO.puts("RELEASED CLAIMS #{released_claims} (#{recovery})")
    end

    print_capacity_status(Map.get(snapshot, :capacity))
    print_polling_status(Map.get(snapshot, :polling))

    supervision_exit_code = print_supervision_health()
    print_ci_readiness()
    print_build_gate_status()
    print_prewarm_status()
    print_blocking_asks(opts)
    exit_marker(supervision_exit_code)
  end

  defp print_polling_status(%{
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

  defp print_polling_status(_polling), do: :ok

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
        {:ok, %{running: running}, freshness} when is_list(running) ->
          print_snapshot_freshness(freshness)
          print_agents_table(running)
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
    guarded("alerts", fn ->
      opts
      |> AlertFeed.list()
      |> Enum.each(&IO.puts(Jason.encode!(&1)))

      exit_marker(0)
    end)
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

  @spec units(keyword()) :: :ok
  def units(opts \\ []) do
    UnitsCLI.run(opts) |> exit_marker()
  end

  @spec build_orders(keyword()) :: :ok
  def build_orders(opts \\ []) do
    guarded("build-orders", fn -> opts |> Keyword.put(:error_fun, &control_error/1) |> BuildOrdersCLI.run() |> exit_marker() end)
  end

  @spec analytics(keyword()) :: :ok
  def analytics(opts \\ []) do
    guarded("analytics", fn -> AnalyticsCLI.run(opts) |> exit_marker() end)
  end

  @spec github_cost(keyword()) :: :ok
  def github_cost(opts \\ []) do
    guarded("github-cost", fn -> GitHubCostCLI.run(opts) |> exit_marker() end)
  end

  @spec executor_emit(String.t(), String.t()) :: :ok
  def executor_emit(topic, payload_json) when is_binary(topic) and is_binary(payload_json) do
    case Jason.decode(payload_json) do
      {:ok, %{} = payload} ->
        case ExecutorEvents.publish(topic, payload, source: :executor_cli) do
          {:ok, id, _subscribers} ->
            IO.puts(Jason.encode!(%{id: id, topic: topic}))
            exit_marker(0)

          {:error, reason} ->
            IO.puts(:stderr, "aiur: executor event rejected (#{format_reason(reason)})")
            exit_marker(1)
        end

      _ ->
        IO.puts(:stderr, "aiur: executor-emit payload must be a JSON object")
        exit_marker(64)
    end
  end

  @spec executor_subscribe(String.t()) :: :ok
  def executor_subscribe(topic) when is_binary(topic) do
    executor_subscription_result(ExecutorEvents.subscribe(topic), "subscribed", topic)
  end

  @spec executor_unsubscribe(String.t()) :: :ok
  def executor_unsubscribe(topic) when is_binary(topic) do
    executor_subscription_result(ExecutorEvents.unsubscribe(topic), "unsubscribed", topic)
  end

  @spec executor_subscriptions() :: :ok
  def executor_subscriptions do
    ExecutorEvents.subscriptions() |> Enum.each(&IO.puts/1)
    exit_marker(0)
  end

  @spec executor_listen(keyword()) :: no_return()
  def executor_listen(opts \\ []), do: ExecutorEvents.listen(opts)

  @spec executor_wait(keyword()) :: :ok
  def executor_wait(opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 300_000)
    json? = Keyword.get(opts, :json, false)

    case ExecutorWakeInbox.wait(timeout_ms) do
      {:ok, records} ->
        print_executor_wakes(records, json?)
        :ok = ExecutorWakeInbox.acknowledge(records)
        exit_marker(0)

      :timeout ->
        exit_marker(75)

      {:error, reason} ->
        control_error("aiur: executor wake inbox unavailable (#{format_reason(reason)})")
        exit_marker(1)
    end
  end

  defp print_executor_wakes(records, true), do: IO.puts(Jason.encode!(records))

  defp print_executor_wakes(records, false) do
    Enum.each(records, fn record ->
      ticket = if record["ticket"], do: " ticket=#{record["ticket"]}", else: ""
      IO.puts("WAKE #{record["topic"]}#{ticket} count=#{record["count"]}")
    end)
  end

  defp executor_subscription_result(:ok, action, topic) do
    IO.puts("#{action} #{topic}")
    exit_marker(0)
  end

  defp executor_subscription_result({:error, reason}, _action, _topic) do
    IO.puts(:stderr, "aiur: executor subscription rejected (#{format_reason(reason)})")
    exit_marker(1)
  end

  # Absolute set of the concurrent-agent cap on a live node — `aiur set
  # max-agents N`. Positive validation lives in the CLI; the orchestrator
  # applies the session cap and reports whether active work is draining down.
  @spec set_max_agents(integer()) :: :ok
  def set_max_agents(n) do
    guarded("set max-agents", fn -> set_max_agents_result(n) end)
  end

  defp set_max_agents_result(n) when is_integer(n) and n > 0 do
    case Orchestrator.set_max_concurrent_agents(n) do
      {:ok, status} ->
        IO.puts("aiur: max-agents set to #{status.max} (#{max_agents_status_suffix(status)})")
        exit_marker(0)

      {:error, reason} ->
        control_error("aiur: failed to set max-agents (#{format_reason(reason)})")
        exit_marker(control_query_exit_code(reason))
    end
  end

  defp set_max_agents_result(_n) do
    control_error("aiur: max-agents must be a positive integer")
    exit_marker(1)
  end

  @spec todo([String.t()], keyword()) :: 0 | 1
  def todo(issue_ids, opts \\ []) when is_list(issue_ids) do
    deps = Keyword.get(opts, :deps, todo_runtime_deps())
    only? = Keyword.get(opts, :only, false)
    emit_exit_marker? = Keyword.get(opts, :emit_exit_marker, false)

    exit_code =
      case deps.ensure_started.() do
        :ok ->
          result =
            case deps.load_config.() do
              {:ok, config} ->
                issue_ids
                |> normalize_todo_ids()
                |> queue_todo_issues(config, deps)
                |> maybe_clear_other_todos(only?, config, deps)
                |> maybe_request_todo_refresh(deps)

              {:error, reason} ->
                IO.puts(:stderr, "aiur: unable to queue tickets (#{format_reason(reason)})")
                todo_result(failures: 1)
            end

          IO.puts("queued #{result.queued} ticket(s); cleared #{result.cleared} other(s)")
          if result.failures == 0, do: 0, else: 1

        {:error, :application_not_started} ->
          IO.puts(:stderr, not_running_message())
          1

        {:error, reason} ->
          IO.puts(:stderr, "aiur: unable to queue tickets (#{format_reason(reason)})")
          IO.puts("queued 0 ticket(s); cleared 0 other(s)")
          1
      end

    if emit_exit_marker?, do: exit_marker(exit_code)
    exit_code
  end

  defp normalize_todo_ids(issue_ids) do
    issue_ids
    |> Enum.map(&(to_string(&1) |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp queue_todo_issues(issue_ids, config, deps) do
    Enum.reduce(issue_ids, todo_result(), &queue_todo_issue(&1, &2, config, deps))
  end

  defp queue_todo_issue(issue_id, result, config, deps) do
    case deps.fetch_issue.(issue_id) do
      {:ok, [issue | _]} -> queue_fetched_todo_issue(issue_id, issue, result, config, deps)
      {:ok, []} -> todo_failure(result, issue_id, "not found")
      {:error, reason} -> todo_failure(result, issue_id, format_reason(reason))
    end
  end

  defp queue_fetched_todo_issue(issue_id, issue, result, config, deps) do
    labels = normalized_issue_labels(issue)
    queue_label = normalized_label(config.queue_label)

    midflight_labels =
      Enum.filter(config.active_labels, &(&1 != queue_label and MapSet.member?(labels, &1)))

    cond do
      terminal_todo_issue?(issue, labels, config) ->
        todo_failure(result, issue_id, "terminal ticket")

      midflight_labels != [] ->
        IO.puts("• ##{issue_id} kept #{Enum.join(midflight_labels, ", ")}")
        select_todo_issue(result, issue_id)

      MapSet.member?(labels, queue_label) ->
        IO.puts("✓ ##{issue_id} already #{config.queue_label}")
        result |> select_todo_issue(issue_id) |> Map.update!(:queued, &(&1 + 1))

      true ->
        add_todo_label(issue_id, result, config, deps)
    end
  end

  defp add_todo_label(issue_id, result, config, deps) do
    case deps.add_label.(issue_id, config.queue_label) do
      :ok ->
        IO.puts("✓ ##{issue_id} → #{config.queue_label}")
        result |> select_todo_issue(issue_id) |> Map.update!(:queued, &(&1 + 1))

      {:error, reason} ->
        todo_failure(
          result,
          issue_id,
          "failed to add #{config.queue_label}: #{format_reason(reason)}"
        )
    end
  end

  defp select_todo_issue(result, issue_id) do
    Map.update!(result, :selected, &MapSet.put(&1, issue_id))
  end

  defp todo_failure(result, issue_id, reason) do
    IO.puts(:stderr, "✗ ##{issue_id} #{reason}")
    Map.update!(result, :failures, &(&1 + 1))
  end

  defp maybe_clear_other_todos(result, false, _config, _deps), do: result

  defp maybe_clear_other_todos(%{failures: failures} = result, true, _config, _deps)
       when failures > 0 do
    IO.puts(
      :stderr,
      "aiur: --only cleanup skipped because #{failures} requested ticket(s) failed"
    )

    result
  end

  defp maybe_clear_other_todos(result, true, config, deps) do
    case deps.fetch_active.(config.active_states) do
      {:ok, issues} ->
        issues
        |> Enum.filter(&clearable_todo?(&1, result, config))
        |> clear_other_todos(result, config, deps)

      {:error, reason} ->
        IO.puts(:stderr, "aiur: failed to enumerate active tickets (#{format_reason(reason)})")
        Map.update!(result, :failures, &(&1 + 1))
    end
  end

  defp clearable_todo?(issue, result, config) do
    issue_id = todo_issue_id(issue)
    labels = normalized_issue_labels(issue)

    not MapSet.member?(result.selected, issue_id) and
      not terminal_todo_issue?(issue, labels, config) and
      MapSet.member?(labels, normalized_label(config.queue_label))
  end

  # Bound the blast radius of one `--only` cleanup run and stop hammering the
  # API once GitHub starts throttling us, rather than issuing throttled
  # DELETEs across the whole batch and leaving a nondeterministic partial
  # queue.
  @max_cleanup_batch 50
  @max_consecutive_rate_limit_failures 3

  defp clear_other_todos(candidates, result, config, deps) do
    {batch, skipped} = Enum.split(candidates, @max_cleanup_batch)

    if skipped != [] do
      IO.puts(
        :stderr,
        "aiur: --only cleanup capped at #{@max_cleanup_batch} ticket(s); #{length(skipped)} other ticket(s) left untouched"
      )
    end

    {result, _consecutive_rate_limited} =
      Enum.reduce_while(batch, {result, 0}, &clear_other_todo_step(&1, &2, config, deps))

    result
  end

  defp clear_other_todo_step(issue, {result, consecutive_rate_limited}, config, deps) do
    issue_id = todo_issue_id(issue)

    case deps.remove_label.(issue_id, config.queue_label) do
      :ok ->
        IO.puts("– ##{issue_id} cleared #{config.queue_label}")
        {:cont, {Map.update!(result, :cleared, &(&1 + 1)), 0}}

      {:error, {:github, :rate_limited, _detail} = reason} ->
        IO.puts(
          :stderr,
          "✗ ##{issue_id} failed to clear #{config.queue_label}: #{format_reason(reason)}"
        )

        result = Map.update!(result, :failures, &(&1 + 1))
        consecutive_rate_limited = consecutive_rate_limited + 1

        if consecutive_rate_limited >= @max_consecutive_rate_limit_failures do
          IO.puts(
            :stderr,
            "aiur: --only cleanup stopped after #{consecutive_rate_limited} consecutive rate-limit failures"
          )

          {:halt, {result, consecutive_rate_limited}}
        else
          {:cont, {result, consecutive_rate_limited}}
        end

      {:error, reason} ->
        IO.puts(
          :stderr,
          "✗ ##{issue_id} failed to clear #{config.queue_label}: #{format_reason(reason)}"
        )

        {:cont, {Map.update!(result, :failures, &(&1 + 1)), 0}}
    end
  end

  defp normalized_issue_labels(issue) do
    issue
    |> Map.get(:labels, [])
    |> Enum.map(&normalized_label/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp terminal_todo_issue?(issue, labels, config) do
    normalized_tracker_state(Map.get(issue, :state)) == "closed" or
      Enum.any?(config.terminal_labels, &MapSet.member?(labels, &1))
  end

  defp todo_issue_id(issue) do
    to_string(Map.get(issue, :identifier) || Map.get(issue, :id) || "")
  end

  defp todo_result(overrides \\ []) do
    Map.merge(%{queued: 0, cleared: 0, failures: 0, selected: MapSet.new()}, Map.new(overrides))
  end

  defp maybe_request_todo_refresh(%{queued: queued, cleared: cleared} = result, deps)
       when queued > 0 or cleared > 0 do
    _ = deps.request_refresh.()
    result
  end

  defp maybe_request_todo_refresh(result, _deps), do: result

  defp todo_runtime_deps do
    %{
      ensure_started: &ensure_todo_runtime_started/0,
      load_config: &load_todo_config/0,
      fetch_issue: fn issue_id -> GitHubTracker.fetch_issue_states_by_ids([issue_id]) end,
      fetch_active: &GitHubTracker.fetch_issues_by_states/1,
      add_label: &GitHubTracker.add_label/2,
      remove_label: &GitHubTracker.remove_label/2,
      request_refresh: &Orchestrator.request_refresh/0
    }
  end

  defp ensure_todo_runtime_started do
    case Application.ensure_all_started(:req) do
      {:ok, _started} ->
        if application_started?() do
          _ = GitHubConfig.resolve_token()
          :ok
        else
          {:error, :application_not_started}
        end

      {:error, reason} ->
        {:error, {:http_client_start_failed, reason}}
    end
  end

  defp load_todo_config do
    with {:ok, settings} <- Config.settings(),
         :ok <- require_github_tracker(settings),
         :ok <- GitHubConfig.validate!() do
      prefix = GitHubConfig.label_prefix()

      {:ok,
       %{
         queue_label: StatePolicy.state_label(prefix, "todo"),
         active_states: settings.tracker.active_states,
         active_labels:
           Enum.map(
             settings.tracker.active_states,
             &(StatePolicy.state_label(prefix, &1) |> normalized_label())
           ),
         terminal_labels:
           Enum.map(
             settings.tracker.terminal_states,
             &(StatePolicy.state_label(prefix, &1) |> normalized_label())
           )
       }}
    end
  end

  defp require_github_tracker(%{tracker: %{kind: "github"}}), do: :ok
  defp require_github_tracker(_settings), do: {:error, "--todo requires a GitHub tracker"}

  defp normalized_label(label) when is_binary(label),
    do: label |> String.trim() |> String.downcase()

  defp normalized_label(_label), do: ""

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

  # `aiur reset-budget <id>...` — the supported exit from the #1453 lifetime
  # dispatch latch. Clears the in-memory + durable budget entries so a latched
  # ticket returns to dispatchable without hand-editing `dispatch-budgets.json`.
  @spec reset_budget([String.t()]) :: :ok
  def reset_budget(targets) when is_list(targets) do
    guarded("reset-budget", fn ->
      results =
        targets
        |> Enum.map(&to_string/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&reset_budget_one/1)

      exit_marker(if Enum.any?(results, &match?({:error, _}, &1)), do: 1, else: 0)
    end)
  end

  defp reset_budget_one(target) do
    case Orchestrator.reset_dispatch_budget(target) do
      {:ok, :queued} ->
        IO.puts("aiur: queued lifetime dispatch budget reset for ##{target}")
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
        IO.puts("aiur: global pause #{if paused, do: "ON — no agents will be provisioned", else: "OFF — agents resuming"}")

        exit_marker(0)

      {:error, reason} ->
        control_error("aiur: failed to #{verb} the daemon (#{format_reason(reason)})")
        exit_marker(control_query_exit_code(reason))
    end
  end

  defp set_global_pause_call(on?, source) do
    Application.get_env(:aiur, :agent_control_cli_set_global_pause_fun, &Orchestrator.set_global_pause/2).(on?, source)
  end

  @spec message(String.t(), String.t()) :: :ok
  def message(issue, text) when is_binary(issue) and is_binary(text) do
    guarded("message", fn ->
      issue
      |> message_status(text, control_status_snapshot())
      |> exit_marker()
    end)
  end

  defp message_status(issue, text, statuses) when is_list(statuses) do
    case Enum.find(statuses, &target_matches?(&1, issue)) do
      nil ->
        print_failure(:message, %{identifier: issue, issue_id: issue}, :no_running_agent)
        1

      status ->
        deliver_message(status, text)
    end
  end

  defp message_status(_issue, _text, error) when error in [:timeout, :unavailable] do
    print_orchestrator_status_error(error)
    control_query_exit_code(error)
  end

  # Empty/whitespace-only and over-long text are validated downstream by
  # Orchestrator.send_operator_message (the shared delivery path), which returns
  # {:error, :empty_message | :message_too_long}; we surface those via format_reason.
  defp deliver_message(status, text) do
    case send_message(canonical_identifier(status), text) do
      {:ok, _request_id} ->
        IO.puts("aiur: messaged #{display_identifier(status)}")
        0

      {:error, reason} ->
        print_failure(:message, status, reason)
        control_query_exit_code(reason)
    end
  end

  defp send_message(identifier, text) do
    Application.get_env(:aiur, :agent_control_cli_message_fun, &AgentChat.send/2).(
      identifier,
      text
    )
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
      {:ok, %{globally_paused: true}} ->
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
    Application.get_env(:aiur, :agent_control_cli_global_pause_status_fun, &Orchestrator.global_pause_status/0).()
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

  # Every resume queued by this invocation is confirmed by one shared polling
  # loop against one shared deadline: a single fleet read per tick settles all
  # of them at once. The wait is therefore bounded by the budget no matter how
  # many targets `--all` selected, and each read is capped by the time actually
  # left so a slow orchestrator cannot walk past the launcher's RPC timeout.
  defp resolve_queued_resumes(results) do
    queued =
      for {:queued_resume, status, request_id} <- results,
          do: %{canonical: canonical_identifier(status), request_id: request_id}

    if queued == [] do
      results
    else
      deadline = System.monotonic_time(:millisecond) + resume_confirm_timeout_ms()
      outcomes = await_resumes_applied(queued, deadline, %{})

      Enum.map(results, fn
        {:queued_resume, status, _request_id} ->
          report_resume(status, Map.fetch!(outcomes, canonical_identifier(status)))

        result ->
          result
      end)
    end
  end

  defp await_resumes_applied(pending, deadline, outcomes) do
    case read_control_states(pending, remaining_ms(deadline)) do
      {:error, error} ->
        if remaining_ms(deadline) <= @resume_confirm_poll_ms do
          settle_all(pending, {:unknown, %{reason: {:status_unreadable, error}}}, outcomes)
        else
          Process.sleep(@resume_confirm_poll_ms)
          await_resumes_applied(pending, deadline, outcomes)
        end

      {:ok, observed} ->
        {settled, waiting} = Enum.split_with(pending, &settled_resume_outcome?(Map.fetch!(observed, &1.canonical)))
        outcomes = Enum.into(settled, outcomes, &{&1.canonical, Map.fetch!(observed, &1.canonical)})

        cond do
          waiting == [] ->
            outcomes

          remaining_ms(deadline) <= @resume_confirm_poll_ms ->
            settle_timed_out(waiting, observed, outcomes)

          true ->
            Process.sleep(@resume_confirm_poll_ms)
            await_resumes_applied(waiting, deadline, outcomes)
        end
    end
  end

  defp settle_timed_out(waiting, observed, outcomes) do
    Enum.into(waiting, outcomes, fn pending_resume ->
      outcome = observed |> Map.fetch!(pending_resume.canonical) |> timeout_resume_outcome()
      {pending_resume.canonical, outcome}
    end)
  end

  defp settle_all(pending, outcome, outcomes), do: Enum.into(pending, outcomes, &{&1.canonical, outcome})

  defp settled_resume_outcome?(:applied), do: true
  defp settled_resume_outcome?({outcome, _detail}) when outcome in [:declined, :dropped], do: true
  defp settled_resume_outcome?(_outcome), do: false

  defp timeout_resume_outcome({:pending, detail}),
    do: {:unknown, Map.put(detail, :reason, :confirmation_window_elapsed)}

  defp timeout_resume_outcome(outcome), do: outcome

  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # Read every queued target from one fleet snapshot. The read never outlives
  # the confirmation budget, and never claims more than the status timeout.
  defp read_control_states(pending, remaining) do
    timeout_ms = remaining |> max(@resume_confirm_poll_ms) |> min(@status_timeout_ms)

    case confirmation_status_snapshot(timeout_ms) do
      statuses when is_list(statuses) ->
        statuses_by_identifier = Map.new(statuses, &{canonical_identifier(&1), &1})

        {:ok,
         Map.new(pending, fn %{canonical: canonical, request_id: request_id} ->
           case Map.get(statuses_by_identifier, canonical) do
             nil -> {canonical, {:unknown, %{reason: :no_longer_tracked}}}
             status -> {canonical, resume_outcome(status, request_id)}
           end
         end)}

      error when error in [:timeout, :unavailable] ->
        {:error, error}
    end
  end

  defp control_status_snapshot do
    Application.get_env(:aiur, :agent_control_cli_status_fun, &Orchestrator.status/0).()
  end

  defp confirmation_status_snapshot(timeout_ms) do
    Application.get_env(:aiur, :agent_control_cli_confirmation_status_fun, &Orchestrator.status/2).(
      Orchestrator,
      timeout_ms
    )
  end

  defp resume_outcome(status, nil) do
    if Map.get(status, :state) == :paused,
      do: paused_resume_outcome(status, nil),
      else: :applied
  end

  defp resume_outcome(status, request_id) do
    latest = resume_control_outcome(status, request_id)

    if is_map(latest) and Map.get(latest, :request_id) == request_id and Map.get(latest, :status) == :applied,
      do: :applied,
      else: paused_resume_outcome(status, request_id, latest)
  end

  defp paused_resume_outcome(status, request_id, latest \\ nil) do
    latest = latest || resume_control_outcome(status, request_id)
    detail = held_resume_detail(status, latest)
    classify_paused_resume(latest, request_id, detail)
  end

  defp classify_paused_resume(latest, request_id, detail) do
    cond do
      not is_map(latest) -> unknown_outcome(detail, :missing_control_outcome)
      mismatched_request?(request_id, latest) -> unknown_outcome(detail, :mismatched_control_outcome)
      Map.get(latest, :action) != :resume -> unknown_outcome(detail, :mismatched_control_outcome)
      true -> resume_status_outcome(latest, detail)
    end
  end

  defp mismatched_request?(nil, _latest), do: false
  defp mismatched_request?(request_id, latest), do: Map.get(latest, :request_id) != request_id

  defp resume_status_outcome(latest, detail) do
    case Map.get(latest, :status) do
      :rejected -> {:declined, detail}
      :expired -> {:dropped, detail}
      status when status in [:requested, :accepted] -> {:pending, detail}
      _other -> unknown_outcome(detail, :inconsistent_control_outcome)
    end
  end

  defp unknown_outcome(detail, reason), do: {:unknown, Map.put(detail, :reason, reason)}

  defp resume_control_outcome(status, request_id) do
    control = Map.get(status, :control, %{})
    recent = Map.get(control, :recent_controls, [])
    correlated = Enum.find(recent, &(Map.get(&1, :request_id) == request_id))

    if is_map(correlated) do
      correlated
    else
      fallback_resume_control(control, request_id)
    end
  end

  defp fallback_resume_control(control, request_id) do
    latest_resume = Map.get(control, :latest_resume_control)
    latest = Map.get(control, :latest_control)

    Enum.find([latest_resume, latest], &matching_control?(&1, request_id)) ||
      latest_resume ||
      latest
  end

  defp matching_control?(control, request_id) when is_map(control) do
    is_nil(request_id) or Map.get(control, :request_id) == request_id
  end

  defp matching_control?(_control, _request_id), do: false

  defp held_resume_detail(status, latest) do
    condition = get_in(latest || %{}, [:rejection, :condition]) || %{}

    %{
      control_status: Map.get(condition, :control_status, Map.get(status, :work_state, :paused)),
      pause_reason: Map.get(condition, :pause_reason, Map.get(status, :pause_reason)),
      status_reason: Map.get(status, :reason),
      rejection: if(is_map(latest), do: Map.get(latest, :rejection)),
      expiry: if(is_map(latest), do: Map.get(latest, :expiry))
    }
  end

  defp report_resume(status, :applied) do
    IO.puts("aiur: resumed #{display_identifier(status)} (was: paused)")
    :ok
  end

  defp report_resume(status, detail) do
    print_unapplied_resume(status, detail)
    {:error, {:resume_unconfirmed, detail}}
  end

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

  defp control_one(:resume, %{state: :running} = status) do
    IO.puts("aiur: already running #{display_identifier(status)}")
    :ok
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
      {:ok, {:resumed, request_id}} when previous_state == :paused ->
        {:queued_resume, status, request_id}

      {:ok, :resumed} when previous_state == :paused ->
        {:queued_resume, status, nil}

      {:ok, result} when result in [:started, :resumed, :reactivated] ->
        IO.puts("aiur: #{result_verb(result)} #{display_identifier(status)} (was: #{previous_state})")

        :ok

      {:error, reason} ->
        print_failure(:resume, status, reason)
        {:error, reason}
    end
  end

  defp print_unapplied_resume(status, {:declined, detail}) do
    control_error("aiur: resume declined for #{display_identifier(status)}; #{held_control_detail(detail)}; #{control_rejection_detail(detail)}")
  end

  defp print_unapplied_resume(status, {:dropped, detail}) do
    control_error("aiur: resume request accepted for #{display_identifier(status)} but the resume dropped (#{dropped_resume_detail(detail)}); #{held_control_detail(detail)}")
  end

  defp print_unapplied_resume(status, {:unknown, detail}) do
    control_error(
      "aiur: resume request accepted for #{display_identifier(status)} but why it was not applied could not be determined (#{unknown_resume_detail(detail)}); #{held_control_detail(detail)}; outcome is unknown"
    )
  end

  defp held_control_detail(detail) do
    status = Map.get(detail, :control_status, :unknown)
    "control status remains #{status} (pause condition: #{pause_condition(detail)})"
  end

  defp pause_condition(%{status_reason: {:paused, :max_agent_duration}}), do: "maximum agent duration reached"
  defp pause_condition(%{pause_reason: :max_agent_duration}), do: "maximum agent duration reached"
  defp pause_condition(%{status_reason: reason}) when not is_nil(reason), do: StatusReason.render(reason)
  defp pause_condition(%{pause_reason: reason}) when not is_nil(reason), do: StatusReason.render(StatusReason.for_pause(reason))
  defp pause_condition(_detail), do: "unknown"

  defp control_rejection_detail(%{rejection: %{message: message}}) when is_binary(message), do: message
  defp control_rejection_detail(%{rejection: %{class: class}}), do: format_reason(class)
  defp control_rejection_detail(_detail), do: "declining rule was not reported"

  defp dropped_resume_detail(%{expiry: %{reason: :timeout}}), do: "timeout"
  defp dropped_resume_detail(%{expiry: %{reason: reason}}), do: format_reason(reason)
  defp dropped_resume_detail(_detail), do: "drop reason was not reported"

  defp unknown_resume_detail(%{reason: {:status_unreadable, error}}), do: "status unreadable: #{format_reason(error)}"

  defp unknown_resume_detail(%{reason: reason}) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp unknown_resume_detail(%{reason: reason}) when not is_nil(reason), do: format_reason(reason)
  defp unknown_resume_detail(_detail), do: "no diagnostic was reported"

  defp resume_confirm_timeout_ms do
    Application.get_env(:aiur, :agent_control_cli_resume_confirm_timeout_ms, @resume_confirm_timeout_ms)
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
        String.pad_trailing(to_string(status.state), 7),
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
        blocked_by_detail(status)
      ]
      |> Enum.reject(&is_nil/1)

    reason_suffix = if reason, do: " (#{reason})", else: ""
    details_suffix = if details == [], do: "", else: " [#{Enum.join(details, "; ")}]"
    reason_suffix <> details_suffix
  end

  defp status_reason_detail(%{reason: reason}) when not is_nil(reason), do: StatusReason.render(reason)
  defp status_reason_detail(_status), do: nil

  defp waiting_reason_detail(%{waiting_reason: reason}) when not is_nil(reason),
    do: "waiting=#{WaitingReason.render(reason)}"

  defp waiting_reason_detail(_status), do: nil

  defp dispatch_decline_detail(%{dispatch_decline_reason: reason}) when not is_nil(reason),
    do: "dispatch_decline=#{reason}"

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

  # The binding constraint is read ONLY from the daemon's own capacity report.
  # The local load sample printed above is deliberately NOT merged in here: the
  # CLI may not run on the daemon's host, and it reads its own config file
  # rather than the daemon's live config, so a locally re-derived gate can name
  # a fleet-level cause the daemon never decided (#1610).
  defp print_capacity_status(%{occupied: occupied, max: max, effective: effective, configured: configured} = capacity)
       when is_integer(occupied) and is_integer(max) and is_integer(effective) and
              is_integer(configured) do
    IO.puts("AGENTS #{occupied}/#{max} (binding: #{capacity_binding_label(capacity_binding(capacity))})")
  end

  defp print_capacity_status(_capacity), do: :ok

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

  defp capacity_binding_label({:config_cap, _detail}), do: "config max_concurrent_agents"
  defp capacity_binding_label({:envelope, detail}), do: "AIMD envelope, effective cap=#{detail}"
  defp capacity_binding_label({:paused_reservations, detail}), do: "paused reservations=#{detail}"
  defp capacity_binding_label({:ticket_supply, _detail}), do: "ticket supply"
  defp capacity_binding_label({:session_cap, _detail}), do: "session max_concurrent_agents"

  defp capacity_binding_label(
         {:admission,
          %{
            signal: :load,
            measured: load,
            threshold: threshold,
            reclaimable_cpu_percent: reclaimable,
            reclaimable_cpu_threshold: reclaimable_threshold
          }}
       ),
       do:
         "load+cpu contention, load=#{load} threshold=#{threshold} " <>
           "reclaimable_cpu=#{reclaimable}% threshold=#{reclaimable_threshold}%"

  defp capacity_binding_label({:admission, %{signal: :load, measured: load, threshold: threshold}}),
    do: "load, load=#{load} threshold=#{threshold}"

  defp capacity_binding_label(
         {:admission,
          %{
            signal: :run_queue,
            measured: runnable,
            threshold: threshold,
            reclaimable_cpu_percent: reclaimable,
            reclaimable_cpu_threshold: reclaimable_threshold
          }}
       ),
       do:
         "run_queue+cpu contention, runnable=#{runnable} threshold=#{threshold} " <>
           "reclaimable_cpu=#{reclaimable}% threshold=#{reclaimable_threshold}%"

  defp capacity_binding_label({:admission, %{signal: :run_queue, measured: runnable, threshold: threshold}}),
    do: "run_queue, runnable=#{runnable} threshold=#{threshold}"

  defp capacity_binding_label({:admission, %{signal: :github_quota, measured: measured}}) do
    case github_quota_measurement(measured) do
      {:current, detail} -> "github_quota, #{detail}"
      {:stale, detail} -> "github_quota stale, #{detail}"
      :unavailable -> "github_quota, measurement unavailable"
    end
  end

  defp capacity_binding_label({:admission, %{signal: signal}}), do: to_string(signal)
  defp capacity_binding_label({:none, _detail}), do: "none"

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

  # `capacity_hold` is the daemon's own persisted admission decision — the only
  # source allowed to name an admission signal as the fleet's binding
  # constraint. Nothing here re-derives a gate locally.
  defp capacity_binding(%{capacity_hold: %{} = hold}),
    do: {:admission, hold}

  defp capacity_binding(%{max: max, effective: effective, configured: configured, occupied: occupied} = capacity) do
    if capacity_binding_ticket_supply?(capacity) do
      {:ticket_supply, 0}
    else
      capacity_binding_with_capacity(capacity, max, effective, configured, occupied)
    end
  end

  # A LOCAL host-pressure reading, taken before the control RPC so the
  # saturation signal survives an RPC timeout (the timeout is most likely
  # precisely when the box is loaded). It is explicitly not a fleet decision:
  # the daemon may run on another host, with another config, and may not be
  # holding at all. So the line says "local host sample" and, when the local
  # reading is over the local threshold, explains that the daemon still needs a
  # short-window CPU sample before it can identify real contention.
  defp print_load_status(%{load: load, load_threshold: threshold, schedulers: schedulers})
       when is_number(load) and is_number(threshold) and is_integer(schedulers) and schedulers > 0 do
    suffix =
      case DispatchPolicy.load_admission_reason(load, threshold, schedulers) do
        {:hold, _reason} ->
          " (local host sample; over load threshold, daemon corroborates CPU contention before holding)"

        :dispatch ->
          " (local host sample)"
      end

    IO.puts("LOAD #{load} threshold=#{threshold * schedulers} schedulers=#{schedulers}#{suffix}")
  end

  defp print_load_status(_capacity), do: :ok

  defp capacity_binding_with_capacity(capacity, max, effective, configured, occupied) do
    cond do
      paused_reservation_binding?(capacity) ->
        {:paused_reservations, capacity.reserved_paused}

      effective < max and occupied >= effective ->
        {:envelope, effective}

      occupied >= max and max == configured and not Map.get(capacity, :session_override?, false) ->
        {:config_cap, configured}

      occupied >= max ->
        {:session_cap, max}

      true ->
        {:none, nil}
    end
  end

  defp capacity_binding_ticket_supply?(%{available: available, queued_demand?: false})
       when is_integer(available) and available > 0,
       do: true

  defp capacity_binding_ticket_supply?(_capacity), do: false

  defp paused_reservation_binding?(%{
         active: active,
         effective: effective,
         available: 0,
         reserved_paused: reserved_paused
       })
       when reserved_paused > 0 and effective > active,
       do: true

  defp paused_reservation_binding?(_capacity), do: false

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
      |> Enum.each(&print_provider_usage/1)

      opts
      |> Keyword.get_lazy(:delivery_modes, fn -> ModePresenter.rows() end)
      |> print_delivery_modes()

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

  defp print_provider_usage({provider, %{state: :unknown}}) do
    IO.puts("#{provider_label(provider)}  no observation yet")
  end

  defp print_provider_usage({provider, view}) do
    windows = usage_windows(view)

    if windows == [] do
      IO.puts("#{provider_label(provider)}  observed #{age_label(view.age_seconds)}, no limit windows reported")
    else
      Enum.each(windows, fn window ->
        IO.puts("#{provider_label(provider)}  #{usage_window_line(window)}  (#{age_label(view.age_seconds)})")
      end)
    end
  end

  defp usage_windows(%{windows: windows}) when is_map(windows) do
    windows
    |> Enum.filter(fn {_id, window} -> Map.get(window, :kind) in [:rate_limit, :credit] end)
    |> Enum.sort_by(fn {id, _window} -> id end)
  end

  defp usage_windows(_view), do: []

  # Claude's CLI reports a standing and a reset time but no utilization, so a
  # bar is not available for it. Name what is known rather than drawing an empty
  # bar, which would read as "0% consumed".
  defp usage_window_line({id, window}) do
    case {
      Map.get(window, :name),
      Map.get(window, :kind),
      Map.get(window, :used),
      Map.get(window, :limit),
      Map.get(window, :used_percent),
      Map.get(window, :credits)
    } do
      {name, :rate_limit, used, limit, _percent, _credits}
      when name in [:concurrency, "Local concurrency"] and is_number(used) and is_number(limit) ->
        "#{String.pad_trailing(id, 10)} #{used}/#{limit} in flight"

      {_name, :credit, _used, _limit, _percent, %{amount: amount}} when is_number(amount) ->
        "#{String.pad_trailing(id, 10)} $#{:erlang.float_to_binary(amount / 1, decimals: 2)} remaining"

      {_name, _kind, _used, _limit, percent, _credits} when is_number(percent) ->
        "#{String.pad_trailing(id, 10)} #{usage_bar(percent)} #{round(percent)}%"

      _unknown ->
        "#{String.pad_trailing(id, 10)} #{window_standing_line(window)}"
    end
  end

  defp window_standing_line(window) do
    case Map.get(window, :standing) do
      :allowed -> "allowed#{cli_reset_suffix(Map.get(window, :resets_at))}"
      :allowed_warning -> "near limit#{cli_reset_suffix(Map.get(window, :resets_at))}"
      :rejected -> "limited#{cli_reset_suffix(Map.get(window, :resets_at))}"
      _unknown -> "unknown"
    end
  end

  defp cli_reset_suffix(%DateTime{} = resets_at) do
    case DateTime.diff(resets_at, DateTime.utc_now()) do
      seconds when seconds <= 0 -> ""
      seconds when seconds < 3_600 -> ", resets in #{div(seconds, 60)}m"
      seconds when seconds < 86_400 -> ", resets in #{div(seconds, 3_600)}h"
      seconds -> ", resets in #{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3_600)}h"
    end
  end

  defp cli_reset_suffix(_resets_at), do: ""

  # Same 10-cell bar the TUI header draws, so the two surfaces read alike.
  @spec usage_bar(number()) :: String.t()
  def usage_bar(percent) when is_number(percent) do
    filled = percent |> max(0) |> min(100) |> Kernel./(10) |> round()
    String.duplicate("█", filled) <> String.duplicate("░", 10 - filled)
  end

  defp age_label(nil), do: "age unknown"
  defp age_label(seconds) when seconds < 60, do: "#{seconds}s ago"
  defp age_label(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m ago"
  defp age_label(seconds), do: "#{div(seconds, 3_600)}h ago"

  defp provider_label(:codex), do: "codex "
  defp provider_label(:claude), do: "claude"
  defp provider_label(other), do: to_string(other)

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

  defp print_global_pause_status_unavailable do
    control_error("GLOBAL PAUSE STATUS UNAVAILABLE — cannot determine whether aiur is paused")
    {:error, :unavailable}
  end

  defp print_global_pause_control_error(action) do
    noun = if action == :pause, do: "pause", else: "resume"
    control_error("error: aiur is globally paused; per-ticket #{noun} has no effect.")
    control_error("Run `aiurdev resume` (no arguments) to lift the global pause.")
  end

  defp format_pause_source(source) when is_binary(source) and source != "", do: "set by #{source}"
  defp format_pause_source(_), do: nil

  defp format_pause_time(%DateTime{} = paused_at), do: "at #{DateTime.to_iso8601(paused_at)}"
  defp format_pause_time(_), do: nil

  # Surface whether the daemon-resident Executor listener (the Command inbox,
  # started by `--executor`) is currently listening. Absence is otherwise
  # indistinguishable from "no Commands were created", which is exactly the
  # silent failure #1961 set out to make visible. The check reflects the live
  # Exchange binding, not "was started once": a listener that lost its binding
  # (Exchange restart) or a launch that forgot `--executor` both report absent.
  defp print_executor_listener_status do
    bindings = Application.get_env(:aiur, :executor_listener_alive_fun, &ExecutorListener.bindings/0).()
    bindings = if is_list(bindings), do: bindings, else: if(bindings, do: ["executor.#"], else: [])
    defaults = Aiur.ExecutorBindings.patterns()
    bound = MapSet.new(bindings)
    missing = Enum.reject(defaults, &MapSet.member?(bound, &1))

    cond do
      bindings == [] ->
        IO.puts("LISTENER absent (no Executor wake path; Commands and PR events will not wake the Executor)")

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
        IO.puts("COMMENT TRUST source=#{source} trusted=[#{accounts}]#{suffix}")

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
      } ->
        suffix = if remaining == [], do: "", else: " (+#{length(remaining)} more)"

        IO.puts(
          "BUILD GATE DEGRADED #{active}/#{capacity} active, #{queued} queued; " <>
            "max_concurrent_builds=#{capacity}; reason=#{issue.reason} path=#{issue.path}#{suffix}; " <>
            "recovery=#{issue.recovery}"
        )

      %{enabled?: true, capacity: capacity, active: active, queued: queued}
      when active > 0 or queued > 0 ->
        IO.puts("BUILD GATE #{active}/#{capacity} active, #{queued} queued (max_concurrent_builds=#{capacity})")

      _ ->
        :ok
    end
  end

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
        String.pad_trailing(to_string(Map.get(agent, :work_state, :working)), 10),
        " ",
        String.pad_trailing(format_runtime(Map.get(agent, :runtime_seconds)), 8),
        " ",
        agent_activity(agent)
      ])
    end)
  end

  defp agent_activity(agent) do
    case Map.get(agent, :work_state, :working) do
      :paused ->
        paused_activity(agent)

      "paused" ->
        paused_activity(agent)

      :deactivated ->
        "(deactivated)"

      "deactivated" ->
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

  # ── aiur watch board ──────────────────────────────────────────────────────

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
      signature: {state, Map.get(status, :complexity), Map.get(status, :work_state, run_state), watch_reason_signature(reason), stuck?, pr_ready?}
    }
  end

  defp watch_state(%{tracker_paused: true}), do: "paused"
  defp watch_state(%{tracker_paused: "true"}), do: "paused"
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
      watch_doing(row)
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
    with {:ok, asks} <- Asks.open(repo), do: {:ok, Enum.filter(asks, &(&1["blocking"] == true))}
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

  defp print_empty_selection(:pause, :all), do: control_error("aiur: pause took no action because there are no running agents")
  defp print_empty_selection(:resume, :all), do: control_error("aiur: resume took no action because there are no paused agents")

  defp print_orchestrator_status_error(error) do
    control_error(
      Map.fetch!(
        %{
          timeout: "aiur: timed out while reading agent status",
          unavailable: "aiur: orchestrator is not running"
        },
        error
      )
    )
  end

  # The old wording said "daemon may be scheduler-saturated". That is a cause,
  # confidently asserted, that this code has no evidence for — and in #1731 it
  # was wrong: the run queue was 1, the host was fine, and one process was
  # head-of-line blocked. A wrong diagnosis printed with confidence is worse
  # than none; it sends the operator to look at host load.
  #
  # So report only what is observable here: which query did not answer, and the
  # state of the process that owed the answer. `Process.info/2` reads the
  # target's mailbox and current function without needing it to be scheduled,
  # which is exactly the measurement an operator would otherwise take by hand.
  #
  # "outcome is unknown" is kept verbatim from #1720/#1812: it is a *different*
  # claim from this one — that the command may or may not have taken effect —
  # and the operator needs both. This adds the evidence, it does not replace it.
  defp print_control_query_error(:timeout, query, timeout_ms) do
    IO.puts(
      "#{@error_marker}aiur: #{query} query timed out after #{format_timeout_budget(timeout_ms)}" <>
        "; outcome is unknown. #{orchestrator_liveness()}"
    )
  end

  defp print_control_query_error(:unavailable, query, _timeout_ms) do
    IO.puts("#{@error_marker}aiur: #{query} query failed because the orchestrator is not running")
  end

  defp orchestrator_liveness do
    case Process.whereis(Orchestrator) do
      nil ->
        "The orchestrator process is not registered, so the daemon is down or still starting."

      pid ->
        describe_orchestrator(Process.info(pid, [:message_queue_len, :status, :current_function]))
    end
  end

  defp describe_orchestrator(nil), do: "The orchestrator process has exited."

  defp describe_orchestrator(info) do
    "Orchestrator mailbox=#{Keyword.get(info, :message_queue_len)} status=#{Keyword.get(info, :status)}" <>
      " in #{format_mfa(Keyword.get(info, :current_function))}. " <>
      "A large mailbox or a blocked current function means one process is stuck, not that the host is busy."
  end

  defp format_mfa({module, function, arity}), do: "#{inspect(module)}.#{function}/#{arity}"
  defp format_mfa(_other), do: "an unknown function"

  defp control_query_exit_code(:timeout), do: 124
  defp control_query_exit_code(_error), do: 1

  defp report_control_query_failure(error, query, timeout_ms) do
    print_control_query_error(error, query, timeout_ms)
    exit_marker(control_query_exit_code(error))
  end

  # Last-resort guard for the read-only query commands (#1684). An unexpected
  # raise or process exit inside a command body used to kill the RPC evaluator
  # outright, and the operator saw a non-zero exit with an empty buffer — the
  # one failure mode indistinguishable from a healthy idle fleet. Whatever goes
  # wrong, the command now says what failed in one line and still emits an exit
  # marker, so the launcher never has to guess.
  @spec guarded(String.t(), (-> :ok)) :: :ok
  defp guarded(query, fun) do
    fun.()
  rescue
    error -> report_control_query_crash(query, Exception.message(error))
  catch
    :exit, {:timeout, {GenServer, :call, [_server, _request, timeout_ms]}}
    when is_integer(timeout_ms) ->
      print_control_query_error(:timeout, query, timeout_ms)
      exit_marker(control_query_exit_code(:timeout))

    :exit, reason ->
      report_control_query_crash(query, "process exited: #{inspect(reason)}")

    kind, payload ->
      report_control_query_crash(query, "#{kind}: #{inspect(payload)}")
  end

  defp report_control_query_crash(query, detail) do
    IO.puts("#{@error_marker}aiur: #{query} query failed (#{single_line(detail)})")
    exit_marker(1)
  end

  defp single_line(text) do
    text |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 300)
  end

  defp control_query_timeout(opts, key, default) do
    case Keyword.get(opts, key, default) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _invalid -> default
    end
  end

  defp format_timeout_budget(timeout_ms) when rem(timeout_ms, 1_000) == 0,
    do: "#{div(timeout_ms, 1_000)}s"

  defp format_timeout_budget(timeout_ms), do: "#{timeout_ms}ms"

  defp application_started? do
    Enum.any?(Application.started_applications(), fn {app, _description, _version} ->
      app == :aiur
    end)
  end

  defp not_running_message do
    "error: aiur is not running. Start it with `aiurdev run` (or `aiurdev --bg`), then retry."
  end

  defp print_failure(:resume, status, {:pause_override_clear_failed, reason}) do
    control_error("aiur: failed to resume #{display_identifier(status)}; resume will not hold because agent:paused could not be removed (#{format_reason(reason)})")
  end

  defp print_failure(:message, status, reason) do
    control_error("aiur: failed to message #{display_identifier(status)} (#{format_message_reason(reason)})")
  end

  defp print_failure(:reset_budget, status, reason) do
    control_error("aiur: failed to reset lifetime dispatch budget for #{display_identifier(status)} (#{format_reason(reason)})")
  end

  defp print_failure(action, status, reason) do
    control_error("aiur: failed to #{action} #{display_identifier(status)} (#{format_reason(reason)})")
  end

  defp control_error(message) do
    message = single_line(message)
    IO.puts(:stderr, message)
    IO.puts("#{@error_marker}#{message}")
  end

  defp target_matches?(status, target) do
    Issue.identifier_matches?(status.issue_id, status.identifier, target)
  end

  defp canonical_identifier(status) do
    to_string(status.identifier || status.issue_id)
  end

  defp pause_agent(identifier) do
    Application.get_env(:aiur, :agent_control_cli_pause_fun, &AgentChat.pause/1).(identifier)
  end

  defp resume_agent(identifier) do
    Application.get_env(:aiur, :agent_control_cli_resume_fun, &AgentChat.resume_with_receipt/1).(identifier)
  end

  defp display_identifier(%{identifier: identifier, issue_id: issue_id}) do
    cond do
      issue_number_suffix(identifier) ->
        "##{issue_number_suffix(identifier)}"

      numeric_identifier?(identifier) ->
        "##{identifier}"

      numeric_identifier?(issue_id) ->
        "##{issue_id}"

      is_binary(identifier) and identifier != "" ->
        identifier

      true ->
        to_string(issue_id)
    end
  end

  defp issue_number_suffix(identifier) when is_binary(identifier) do
    case Regex.run(~r/#(\d+)$/, identifier) do
      [_, number] -> number
      _ -> nil
    end
  end

  defp issue_number_suffix(_identifier), do: nil

  defp numeric_identifier?(identifier) when is_binary(identifier),
    do: Regex.match?(~r/^\d+$/, identifier)

  defp numeric_identifier?(_identifier), do: false

  defp activity_payload(message) do
    case map_value(message, ["payload", :payload]) do
      payload when is_map(payload) -> payload
      _ -> message
    end
  end

  defp result_verb(result),
    do: Map.fetch!(%{resumed: "resumed", started: "started", reactivated: "reactivated"}, result)

  defp format_reason({:stale_tracker_state, reason, details}) do
    changed_context =
      case Map.get(details, :changed_fields, []) do
        [] -> ""
        fields -> ", changed=#{Enum.join(fields, ",")}"
      end

    paused_context =
      if Map.get(details, :cached_paused) != Map.get(details, :tracker_paused) do
        ", cached_paused=#{details.cached_paused}, tracker_paused=#{details.tracker_paused}"
      else
        ""
      end

    "tracker cache was stale: cached=#{details.cached_state}, tracker=#{details.tracker_state}#{changed_context}#{paused_context}; #{format_reason(reason)}"
  end

  defp format_reason({:tracker_state_not_resumable, state}),
    do: "tracker state #{state} is not resumable"

  defp format_reason({:tracker_refresh_failed, reason}),
    do: "tracker refresh failed: #{format_reason(reason)}"

  defp format_reason({:state_concurrency_limit_reached, state}),
    do: "state concurrency limit reached for #{state}"

  # Keep the real fault visible instead of collapsing it to a cause the CLI
  # has not established (#1634).
  defp format_reason({:orchestrator_call_failed, reason}),
    do: "orchestrator call failed: #{inspect(reason)}"

  defp format_reason({:dispatch_failed, :no_worker_capacity}),
    do: "dispatch failed because no worker capacity is available; retry after a worker slot is free"

  defp format_reason({:dispatch_failed, :state_capacity}),
    do: "dispatch failed because this ticket state is at capacity; retry after an agent in the same state finishes"

  defp format_reason({:dispatch_failed, :fleet_capacity}),
    do: "dispatch failed because the fleet is at max concurrent agent capacity; retry after an agent slot is free"

  defp format_reason({:dispatch_failed, :all_backends_usage_limited}),
    do: "dispatch failed because every configured backend is usage-limited; retry after a provider limit resets"

  defp format_reason({:dispatch_failed, :thrash_circuit_open}),
    do: "dispatch failed because the restart circuit is open; retry after the restart window resets or run `aiurdev reset-budget <id>`"

  defp format_reason({:dispatch_failed, {:dispatch_declined, reason}}),
    do: "dispatch was declined (#{inspect(reason)}); retry after the ticket state, labels, or tracker visibility becomes dispatchable"

  defp format_reason({:dispatch_failed, {:worker_start_failed, reason}}),
    do: "dispatch failed while starting the worker (#{inspect(reason)}); inspect the daemon alert and retry after the worker failure clears"

  defp format_reason({:dispatch_failed, :cause_unknown}),
    do: "dispatch failed, but the daemon could not determine the cause; inspect `aiurdev alerts` and the daemon log before retrying"

  defp format_reason({:dispatch_failed, reason}),
    do: "dispatch failed for #{inspect(reason)}, but the daemon could not determine what clears it; inspect `aiurdev alerts` and the daemon log before retrying"

  defp format_reason({:redispatch_deferred, :max_concurrent_agents_reached}),
    do: "redispatch deferred by max concurrent agent capacity; it clears when an agent slot is free"

  defp format_reason({:redispatch_deferred, :no_worker_capacity}),
    do: "redispatch deferred because no worker capacity is available; it clears when a worker slot is free"

  defp format_reason({:redispatch_deferred, :preferred_worker_unavailable}),
    do: "redispatch deferred because the preferred worker is not selectable for this backend; it clears when a compatible worker is available or routing selects a compatible backend"

  defp format_reason({:redispatch_deferred, :thrash_circuit_open}),
    do: "redispatch deferred by the restart circuit; it clears when the restart window resets or `reset-budget` clears the latch"

  defp format_reason({:redispatch_deferred, {:all_limited, backends}}),
    do: "redispatch deferred because every fallback backend is usage-limited (#{Enum.join(backends, ", ")}); it clears after a provider limit resets"

  defp format_reason({:redispatch_deferred, {:unknown_backend, backend}}),
    do: "redispatch deferred because backend #{inspect(backend)} is not configured; it clears after the ticket selects a configured backend"

  defp format_reason({:redispatch_deferred, {:not_dispatchable, reason}}),
    do: "redispatch deferred because the refreshed ticket is not dispatchable (#{inspect(reason)}); it clears after its state, labels, or blockers become eligible"

  defp format_reason({:redispatch_deferred, :missing_after_revalidation}),
    do: "redispatch deferred because the ticket disappeared during tracker revalidation; retry after tracker visibility is restored"

  defp format_reason({:redispatch_deferred, {:tracker_revalidation_failed, reason}}),
    do: "redispatch deferred because tracker revalidation failed (#{inspect(reason)}); it clears after tracker access recovers"

  defp format_reason({:redispatch_deferred, {:worker_start_failed, reason}}),
    do: "redispatch was admitted but the replacement worker failed to start (#{inspect(reason)}); it clears after the worker startup failure is repaired"

  defp format_reason({:redispatch_deferred, :cause_unknown}),
    do: "redispatch was admitted but no replacement worker started; the cause and clearing condition could not be determined, so inspect `aiurdev alerts` and the daemon log before retrying"

  defp format_reason({:redispatch_deferred, reason}),
    do: "redispatch deferred for #{inspect(reason)}; what clears it could not be determined, so inspect `aiurdev alerts` and the daemon log before retrying"

  defp format_reason(reason) do
    Map.get(
      %{
        no_running_agent: "no running agent",
        agent_finished: "agent finished",
        max_concurrent_agents_reached: "max concurrent agents reached",
        below_active_count: "below active agent count",
        not_resumable: "not resumable",
        empty_message: "message is empty",
        message_too_long: "message is too long",
        invalid_message: "invalid message",
        unavailable: "orchestrator unavailable",
        orchestrator_unavailable: "orchestrator unavailable",
        timeout: "orchestrator timed out",
        unknown_issue: "unknown issue",
        tracker_issue_not_found: "tracker issue not found",
        invalid_tracker_issue: "tracker returned an invalid issue",
        contradictory_tracker_state_labels: "tracker returned contradictory state labels",
        not_routable_to_worker: "ticket is not routable to a worker",
        dispatch_not_authorized: "tracker label provenance does not authorize dispatch",
        pause_override_still_present: "tracker pause override is still present",
        waiting_for_dependencies: "ticket is waiting for dependencies",
        already_claimed: "ticket is already claimed for dispatch",
        auto_resume_pending: "ticket already has a scheduled automatic resume",
        workspace_ownership_waiting: "ticket is waiting for workspace ownership recovery",
        no_worker_capacity: "no worker capacity",
        dispatch_retry_scheduled: "dispatch failed and a retry was scheduled",
        all_model_backends_limited: "all configured model backends are usage-limited",
        thrash_circuit_open: "dispatch restart circuit is open",
        dispatch_not_started: "dispatch did not start; inspect the ticket attention feed",
        lifetime_dispatch_latch: "lifetime dispatch latch (run `aiurdev reset-budget <id>` to clear; resume cannot)",
        dispatch_failed: "dispatch failed"
      },
      reason,
      inspect(reason)
    )
  end

  defp format_message_reason(:agent_finished), do: "agent is not accepting messages (agent finished)"
  defp format_message_reason(:immediate_not_supported), do: "agent is not accepting immediate messages"
  defp format_message_reason(:interrupt_not_supported), do: "agent is not accepting interrupt messages"
  defp format_message_reason(reason), do: format_reason(reason)

  defp exit_marker(code) do
    IO.puts("#{@exit_marker}#{code}")
    :ok
  end
end
