defmodule Aiur.Orchestrator.StatusCLI.Watch do
  @moduledoc false
  alias Aiur.AlertFeed
  alias Aiur.Commands
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Orchestrator.StatusReason
  alias Aiur.Orchestrator.WaitingReason
  import Aiur.Orchestrator.ControlCLI.Output, only: [display_identifier: 1]
  import Aiur.ControlCLI.Protocol, only: [exit_marker: 1]
  alias Aiur.Orchestrator.StatusCLI.AgentsTable
  alias Aiur.Orchestrator.StatusCLI.Diagnostics
  alias Aiur.Orchestrator.StatusCLI.StatusTable

  # Preserve the node-global baseline across mixed-version RPCs.
  @watch_baseline_key {Aiur.AgentControlCLI, :watch_baseline}
  @watch_stuck_after_seconds 600
  @watch_header "TICKET  STATE         CX  AGE     DOING"

  @doc false
  @spec print_watch_board(term(), term()) :: term()
  def print_watch_board(statuses, opts) do
    Diagnostics.print_prewarm_status()

    tracker_states = StatusTable.tracker_state_sets()

    rows =
      statuses
      |> Enum.filter(&StatusTable.visible_status_row?(&1, tracker_states))
      |> Enum.map(&watch_row/1)
      |> Enum.sort_by(& &1.sort_key)

    alerts = latest_attention_alerts(opts)
    blocking_asks = blocking_asks(opts)
    mode = Keyword.get(opts, :mode, :changes)
    {changed, removed} = update_watch_baseline(rows)
    render_watch(rows, alerts, blocking_asks, mode, changed, removed)
    exit_marker(0)
  end

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

  defp watch_activity(status), do: AgentsTable.agent_activity(status)

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
      String.pad_trailing(AgentsTable.truncate(row.state, 13), 13),
      " ",
      String.pad_trailing(format_complexity(row.complexity), 2),
      " ",
      String.pad_trailing(AgentsTable.format_runtime(row.age_seconds), 7),
      " ",
      watch_doing(row),
      row.waiting
    ]
  end

  defp watch_doing(%{stuck?: true, doing: doing}), do: "⚠ stuck · " <> AgentsTable.truncate(doing, 68)
  defp watch_doing(%{doing: doing}), do: AgentsTable.truncate(doing, 80)

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
      "! BLOCKING ASK #{ask["id"]} · #{ask["urgency"]} · #{ask["created_at"]} · #{AgentsTable.truncate(ask["title"], 56)}"
    end)
  end

  defp watch_ask_lines({:error, reason}),
    do: ["! BLOCKING ASKS UNAVAILABLE · #{format_ask_store_error(reason)}"]

  @doc false
  @spec print_blocking_asks(term()) :: term()
  def print_blocking_asks(opts) do
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
      "~ #{row.id} stuck · no activity for #{AgentsTable.format_runtime(row.age_seconds)}"
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
end
