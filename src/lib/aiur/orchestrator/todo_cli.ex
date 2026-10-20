defmodule Aiur.Orchestrator.TodoCLI do
  @moduledoc false
  # Keep the budget, queueing and cleanup contract together for this one CLI verb.
  alias Aiur.{Config, Orchestrator, Tracker}
  alias Aiur.ControlCLI.Reasons
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.StatePolicy
  alias Aiur.Orchestrator.TicketTransition
  import Aiur.ControlCLI.Protocol, only: [application_started?: 0, exit_marker: 1, not_running_message: 0]

  # `--todo` is the one control command whose runtime scales with its arguments
  # and the tracker's size rather than with daemon state: every requested ID is
  # a GitHub issue fetch, and `--only` adds an active-ticket enumeration plus up
  # to @max_cleanup_batch serial label DELETEs. Against a repo with a deep
  # `agent:todo` queue that is far more than the launcher's shared 10s control
  # budget, so the watchdog killed the RPC mid-flight and printed "outcome is
  # unknown" while labels were half-applied — `--only` scoping was unusable
  # (#2519). The launcher now sizes its watchdog to the requested work and hands
  # us a slightly shorter `budget_ms`. Stop ourselves at that budget so the
  # summary and the exit marker always reach the operator, and a partial run
  # reports exactly what it did instead of nothing at all.
  @spec todo([String.t()], keyword()) :: 0 | 1
  def todo(issue_ids, opts \\ []) when is_list(issue_ids) do
    deps = Keyword.get(opts, :deps, todo_runtime_deps())
    only? = Keyword.get(opts, :only, false)
    emit_exit_marker? = Keyword.get(opts, :emit_exit_marker, false)
    budget = todo_budget(Keyword.get(opts, :budget_ms), deps)

    exit_code =
      case deps.ensure_started.() do
        :ok ->
          result =
            case deps.load_config.() do
              {:ok, config} ->
                issue_ids
                |> normalize_todo_ids()
                |> queue_todo_issues(config, deps, budget)
                |> maybe_clear_other_todos(only?, config, deps, budget)
                |> maybe_request_todo_refresh(deps)

              {:error, reason} ->
                IO.puts(:stderr, "aiur: unable to queue tickets (#{Reasons.format_reason(reason)})")
                todo_result(failures: 1)
            end

          IO.puts("queued #{result.queued} ticket(s); cleared #{result.cleared} other(s)#{todo_kept_suffix(result)}")
          if result.failures == 0, do: 0, else: 1

        {:error, :application_not_started} ->
          IO.puts(:stderr, not_running_message())
          1

        {:error, reason} ->
          IO.puts(:stderr, "aiur: unable to queue tickets (#{Reasons.format_reason(reason)})")
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

  defp queue_todo_issues(issue_ids, config, deps, budget) do
    issue_ids
    |> Enum.with_index()
    |> Enum.reduce_while(todo_result(), fn {issue_id, index}, result ->
      if todo_budget_exhausted?(budget) do
        {:halt, todo_budget_queue_halt(result, Enum.drop(issue_ids, index), budget)}
      else
        {:cont, queue_todo_issue(issue_id, result, config, deps)}
      end
    end)
  end

  # A budget stop must read as a definite partial outcome, never as the silent
  # truncation the 10s watchdog produced: name the tickets that were never
  # touched and count them as failures so the exit code, the printed summary and
  # the tracker all agree. Counting them also fails `--only` cleanup closed via
  # the existing failure guard, so a half-queued request can never go on to
  # dequeue everything else.
  defp todo_budget_queue_halt(result, [], _budget), do: result

  defp todo_budget_queue_halt(result, not_reached, budget) do
    IO.puts(
      :stderr,
      "aiur: --todo stopped after its #{todo_budget_seconds(budget)}s daemon budget; #{length(not_reached)} requested ticket(s) not reached (#{todo_id_summary(not_reached)})"
    )

    IO.puts(:stderr, todo_budget_retry_hint())
    Map.update!(result, :failures, &(&1 + length(not_reached)))
  end

  # Unlike @max_cleanup_batch — a documented, deterministic bound an operator can
  # predict — a budget stop breaks `--only`'s contract that no other ticket is
  # left queued. Exit non-zero so a script can tell the difference.
  defp todo_budget_cleanup_halt(result, [], _budget), do: result

  defp todo_budget_cleanup_halt(result, not_reached, budget) do
    IO.puts(
      :stderr,
      "aiur: --only cleanup stopped after its #{todo_budget_seconds(budget)}s daemon budget; #{length(not_reached)} other ticket(s) left untouched"
    )

    IO.puts(:stderr, todo_budget_retry_hint())
    Map.update!(result, :failures, &(&1 + length(not_reached)))
  end

  defp todo_budget_retry_hint do
    "aiur: rerun to continue, or raise AIUR_CONTROL_RPC_TIMEOUT_SECONDS to allow a longer run"
  end

  # Keep the diagnostic one readable line even when a large batch is cut short.
  @todo_id_summary_limit 10

  defp todo_id_summary(ids) do
    case Enum.split(ids, @todo_id_summary_limit) do
      {shown, []} -> Enum.map_join(shown, ", ", &"##{&1}")
      {shown, rest} -> Enum.map_join(shown, ", ", &"##{&1}") <> ", … and #{length(rest)} more"
    end
  end

  defp todo_budget(budget_ms, deps) when is_integer(budget_ms) and budget_ms > 0 do
    now_ms = todo_now_ms_fun(deps)
    %{budget_ms: budget_ms, deadline_ms: now_ms.() + budget_ms, now_ms: now_ms}
  end

  defp todo_budget(_budget_ms, deps) do
    %{budget_ms: nil, deadline_ms: nil, now_ms: todo_now_ms_fun(deps)}
  end

  defp todo_now_ms_fun(deps), do: Map.get(deps, :now_ms, &monotonic_now_ms/0)

  defp monotonic_now_ms, do: System.monotonic_time(:millisecond)

  defp todo_budget_seconds(%{budget_ms: budget_ms}), do: div(budget_ms + 999, 1000)

  defp todo_budget_exhausted?(%{deadline_ms: nil}), do: false
  defp todo_budget_exhausted?(%{deadline_ms: deadline_ms, now_ms: now_ms}), do: now_ms.() >= deadline_ms

  defp queue_todo_issue(issue_id, result, config, deps) do
    case deps.fetch_issue.(issue_id) do
      {:ok, [issue | _]} -> queue_fetched_todo_issue(issue_id, issue, result, config, deps)
      {:ok, []} -> todo_failure(result, issue_id, "not found")
      {:error, reason} -> todo_failure(result, issue_id, Reasons.format_reason(reason))
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
        result |> select_todo_issue(issue_id) |> Map.update!(:kept, &(&1 + 1))

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
          "failed to add #{config.queue_label}: #{Reasons.format_reason(reason)}"
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

  defp maybe_clear_other_todos(result, false, _config, _deps, _budget), do: result

  defp maybe_clear_other_todos(%{failures: failures} = result, true, _config, _deps, _budget)
       when failures > 0 do
    IO.puts(
      :stderr,
      "aiur: --only cleanup skipped because #{failures} requested ticket(s) failed"
    )

    result
  end

  defp maybe_clear_other_todos(result, true, config, deps, budget) do
    if todo_budget_exhausted?(budget) do
      todo_budget_enumeration_halt(result, budget)
    else
      fetch_and_clear_other_todos(result, config, deps, budget)
    end
  end

  # The active-ticket enumeration is the most expensive call on this path — a
  # paginated search across every active state. Once the budget is gone, paying
  # for it only to halt at the first DELETE would burn the grace window the
  # launcher left us for reporting the outcome.
  defp todo_budget_enumeration_halt(result, budget) do
    IO.puts(
      :stderr,
      "aiur: --only cleanup skipped; the #{todo_budget_seconds(budget)}s daemon budget elapsed while queueing the requested tickets"
    )

    IO.puts(:stderr, todo_budget_retry_hint())
    Map.update!(result, :failures, &(&1 + 1))
  end

  defp fetch_and_clear_other_todos(result, config, deps, budget) do
    case deps.fetch_active.(config.active_states) do
      {:ok, issues} ->
        issues
        |> Enum.filter(&clearable_todo?(&1, result, config))
        |> clear_other_todos(result, config, deps, budget)

      {:error, reason} ->
        IO.puts(:stderr, "aiur: failed to enumerate active tickets (#{Reasons.format_reason(reason)})")
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

  defp clear_other_todos(candidates, result, config, deps, budget) do
    {batch, skipped} = Enum.split(candidates, @max_cleanup_batch)

    if skipped != [] do
      IO.puts(
        :stderr,
        "aiur: --only cleanup capped at #{@max_cleanup_batch} ticket(s); #{length(skipped)} other ticket(s) left untouched"
      )
    end

    {result, _consecutive_rate_limited} =
      batch
      |> Enum.with_index()
      |> Enum.reduce_while({result, 0}, fn {issue, index}, {result, consecutive_rate_limited} ->
        if todo_budget_exhausted?(budget) do
          {:halt, {todo_budget_cleanup_halt(result, Enum.drop(batch, index), budget), consecutive_rate_limited}}
        else
          clear_other_todo_step(issue, {result, consecutive_rate_limited}, config, deps)
        end
      end)

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
          "✗ ##{issue_id} failed to clear #{config.queue_label}: #{Reasons.format_reason(reason)}"
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
          "✗ ##{issue_id} failed to clear #{config.queue_label}: #{Reasons.format_reason(reason)}"
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
    normalized_label(Map.get(issue, :state)) == "closed" or
      Enum.any?(config.terminal_labels, &MapSet.member?(labels, &1))
  end

  defp todo_issue_id(issue) do
    to_string(Map.get(issue, :identifier) || Map.get(issue, :id) || "")
  end

  defp todo_result(overrides \\ []) do
    Map.merge(%{queued: 0, kept: 0, cleared: 0, failures: 0, selected: MapSet.new()}, Map.new(overrides))
  end

  # The refresh is what lets a queued ticket dispatch before the idle backoff
  # timer runs out. It is best-effort, but a dropped wake must not be silent:
  # the operator otherwise watches a 600s countdown that nothing shortened and
  # has no way to tell whether the daemon heard them (#2640). The hint carries
  # the queued identifiers so the daemon keeps polling at the base interval
  # until it has actually seen them.
  # A ticket the operator asked for that is already mid-flight (`agent:rework`
  # after a reviewer asked for changes is the common one) keeps its own label,
  # so it adds nothing to `queued`. Gating the refresh on `queued > 0 or
  # cleared > 0` therefore made `aiur --todo 138 139 …` a total no-op when every
  # requested ticket was mid-flight: no label write, no poll wake, and the
  # daemon sat out its idle backoff while the operator watched free slots. The
  # selected set — which already carries the kept identifiers — is what the
  # refresh is for, so it is what decides whether to send one.
  defp maybe_request_todo_refresh(result, deps) do
    if MapSet.size(result.selected) > 0 or result.cleared > 0 do
      request_todo_refresh(result, deps)
    else
      result
    end
  end

  defp todo_kept_suffix(%{kept: kept}) when kept > 0, do: "; kept #{kept} in flight"
  defp todo_kept_suffix(_result), do: ""

  defp request_todo_refresh(result, deps) do
    case deps.request_refresh.(Enum.sort(result.selected)) do
      :unavailable ->
        IO.puts(:stderr, "aiur: the daemon did not accept a poll refresh; queued tickets wait for its next scheduled poll")

      %{latest_dispatch_hold: %{reasons: reasons}} when is_list(reasons) and reasons != [] ->
        hold = Enum.map_join(reasons, ", ", &to_string/1)
        IO.puts(:stderr, "aiur: latest dispatcher hold: #{hold}; the next poll will reconsider queued tickets")

      _accepted ->
        :ok
    end

    result
  end

  defp todo_runtime_deps do
    %{
      ensure_started: &ensure_todo_runtime_started/0,
      load_config: &load_todo_config/0,
      fetch_issue: fn issue_id -> Tracker.fetch_issue_states_by_ids([issue_id]) end,
      fetch_active: &Tracker.fetch_issues_by_states/1,
      add_label: &TicketTransition.write_marker(&1, :add, &2, writer: :cli_todo),
      remove_label: &TicketTransition.write_marker(&1, :remove, &2, writer: :cli_todo),
      request_refresh: &Orchestrator.note_queued_demand/1,
      now_ms: &monotonic_now_ms/0
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
end
