defmodule Aiur.AgentControlCLI do
  @moduledoc false

  alias Aiur.{AgentChat, AlertFeed, Config, Orchestrator}
  alias Aiur.Codex.EventHumanizer, as: CodexEventHumanizer
  import Aiur.EventHumanizerHelpers, only: [map_value: 2]

  @exit_marker "__AIUR_CONTROL_EXIT__:"

  # `aiur watch` remembers the last board it reported (per-row signature) in a
  # node-local persistent term so `--changes` can print only state-level deltas
  # across one-shot RPC invocations. Updated at operator cadence (minutes), so
  # the persistent_term churn is negligible.
  @watch_baseline_key {__MODULE__, :watch_baseline}
  @watch_stuck_after_seconds 600

  @spec status() :: :ok
  def status do
    case Orchestrator.status() do
      statuses when is_list(statuses) ->
        statuses
        |> Enum.filter(&visible_status_row?/1)
        |> print_status_table()

        exit_marker(0)

      error ->
        print_orchestrator_status_error(error)
        exit_marker(1)
    end
  end

  # Concise one-line-per-agent activity summary — the built-in, headless
  # equivalent of the dashboard / `aiur-status` log-tailing skill. Pulls the
  # orchestrator snapshot (richer than `status/0`: work-state + latest
  # activity) and prints state + what each agent is doing right now.
  @spec agents() :: :ok
  def agents do
    case Orchestrator.snapshot(Orchestrator, 10_000) do
      %{running: running} when is_list(running) ->
        print_agents_table(running)
        exit_marker(0)

      error when error in [:timeout, :unavailable] ->
        print_orchestrator_status_error(error)
        exit_marker(1)

      _other ->
        print_orchestrator_status_error(:unavailable)
        exit_marker(1)
    end
  end

  # `aiur watch` — the server-side status board. Compiles one row per active
  # agent (state · complexity · activity-age · what it's doing) plus an
  # actionable section (needs-attention alerts, stuck agents, PR-ready) entirely
  # from aiur's own state — the orchestrator status snapshot + the persisted
  # alert feed — with no GitHub round-trip. `mode: :full` prints every row;
  # `mode: :changes` (the default) prints only rows whose state-level signature
  # changed since the previous call, keeping the periodic operator pull cheap.
  @spec watch(keyword()) :: :ok
  def watch(opts \\ []) do
    case Orchestrator.status() do
      statuses when is_list(statuses) ->
        rows =
          statuses
          |> Enum.filter(&visible_status_row?/1)
          |> Enum.map(&watch_row/1)
          |> Enum.sort_by(& &1.sort_key)

        alerts = latest_attention_alerts(opts)
        mode = Keyword.get(opts, :mode, :changes)
        {changed, removed} = update_watch_baseline(rows)
        render_watch(rows, alerts, mode, changed, removed)
        exit_marker(0)

      error ->
        print_orchestrator_status_error(error)
        exit_marker(1)
    end
  end

  @spec alerts(keyword()) :: :ok
  def alerts(opts \\ []) do
    opts
    |> AlertFeed.list()
    |> Enum.each(&IO.puts(Jason.encode!(&1)))

    exit_marker(0)
  end

  # Absolute set of the concurrent-agent cap on a live node — `aiur set
  # max-agents N`. Positive validation lives in the CLI; the orchestrator
  # applies the session cap and reports whether active work is draining down.
  @spec set_max_agents(integer()) :: :ok
  def set_max_agents(n) when is_integer(n) and n > 0 do
    case Orchestrator.set_max_concurrent_agents(n) do
      {:ok, status} ->
        IO.puts("aiur: max-agents set to #{status.max} (#{max_agents_status_suffix(status)})")
        exit_marker(0)

      {:error, reason} ->
        IO.puts(:stderr, "aiur: failed to set max-agents (#{format_reason(reason)})")
        exit_marker(1)
    end
  end

  def set_max_agents(_n) do
    IO.puts(:stderr, "aiur: max-agents must be a positive integer")
    exit_marker(1)
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

  @spec message(String.t(), String.t()) :: :ok
  def message(issue, text) when is_binary(issue) and is_binary(text) do
    issue
    |> message_status(text, Orchestrator.status())
    |> exit_marker()
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
    1
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
        1
    end
  end

  defp send_message(identifier, text) do
    Application.get_env(:aiur, :agent_control_cli_message_fun, &AgentChat.send/2).(identifier, text)
  end

  defp control(action, targets) when action in [:pause, :resume] do
    action
    |> control_status(targets, Orchestrator.status())
    |> exit_marker()
  end

  defp control_status(action, targets, statuses) when is_list(statuses) do
    action
    |> select_targets(targets, statuses)
    |> control_selected(action, targets)
  end

  defp control_status(_action, _targets, error) when error in [:timeout, :unavailable] do
    print_orchestrator_status_error(error)
    1
  end

  defp control_selected([], action, targets) do
    print_empty_selection(action, targets)
    0
  end

  defp control_selected(selected, action, _targets) do
    results = Enum.map(selected, &control_one(action, &1))
    failed = Enum.count(results, &match?({:error, _}, &1))

    if failed == length(results), do: 1, else: 0
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
    canonical = canonical_identifier(status)

    case resume_agent(canonical) do
      {:ok, result} when result in [:resumed, :started] ->
        IO.puts("aiur: #{result_verb(result)} #{display_identifier(status)} (was: paused)")
        :ok

      {:error, reason} ->
        print_failure(:resume, status, reason)
        {:error, reason}
    end
  end

  defp control_one(:resume, %{state: :running} = status) do
    IO.puts("aiur: already running #{display_identifier(status)}")
    :ok
  end

  defp control_one(:resume, %{state: :idle} = status) do
    canonical = canonical_identifier(status)

    case resume_agent(canonical) do
      {:ok, result} when result in [:started, :resumed] ->
        IO.puts("aiur: #{result_verb(result)} #{display_identifier(status)} (was: idle)")
        :ok

      {:error, reason} ->
        print_failure(:resume, status, reason)
        {:error, reason}
    end
  end

  defp control_one(:resume, status) do
    print_failure(:resume, status, :no_running_agent)
    {:error, :no_running_agent}
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
        to_string(status.title || "")
      ])
    end)
  end

  defp visible_status_row?(%{work_state: :deactivated}), do: false
  defp visible_status_row?(%{work_state: "deactivated"}), do: false

  defp visible_status_row?(%{state: :idle, tracker_state: tracker_state}) do
    active_tracker_state?(tracker_state) and not terminal_tracker_state?(tracker_state)
  end

  defp visible_status_row?(%{tracker_state: tracker_state}) do
    not terminal_tracker_state?(tracker_state)
  end

  defp visible_status_row?(_status), do: true

  defp active_tracker_state?(tracker_state) when is_binary(tracker_state) do
    tracker_state
    |> normalized_tracker_state()
    |> then(&MapSet.member?(active_tracker_states(), &1))
  end

  defp active_tracker_state?(_tracker_state), do: false

  defp terminal_tracker_state?(tracker_state) when is_binary(tracker_state) do
    tracker_state
    |> normalized_tracker_state()
    |> then(&MapSet.member?(terminal_tracker_states(), &1))
  end

  defp terminal_tracker_state?(_tracker_state), do: false

  defp active_tracker_states do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalized_tracker_state/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp terminal_tracker_states do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalized_tracker_state/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalized_tracker_state(state) when is_binary(state), do: String.downcase(String.trim(state))
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

  defp structured_activity?(%{message: message}) when is_map(message), do: structured_activity?(message)

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

  defp activity_string(value), do: value |> inspect(limit: 5, printable_limit: 120) |> String.trim()

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
      signature: {state, Map.get(status, :complexity), Map.get(status, :work_state, run_state), stuck?, pr_ready?}
    }
  end

  defp watch_state(%{tracker_paused: true}), do: "paused"
  defp watch_state(%{tracker_paused: "true"}), do: "paused"
  defp watch_state(status), do: to_string(status[:tracker_state] || status[:state] || "")

  defp watch_activity(%{tracker_paused: true}), do: "(paused: label override)"
  defp watch_activity(%{tracker_paused: "true"}), do: "(paused: label override)"
  defp watch_activity(%{tracker_state: "ci-wait"}), do: "(waiting for CI)"
  defp watch_activity(%{state: "ci-wait"}), do: "(waiting for CI)"
  defp watch_activity(%{state: :idle}), do: "(idle)"
  defp watch_activity(status), do: agent_activity(status)

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
    |> Keyword.merge(Keyword.take(opts, [:roots, :log_roots]))
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

    changed = for {key, {sig, _id}} <- current, baseline_signature(previous, key) != sig, into: MapSet.new(), do: key
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

  defp render_watch(rows, alerts, mode, changed, removed) do
    rows
    |> watch_rows_for_mode(mode, changed)
    |> print_watch_table(mode)

    print_watch_actionable(rows, alerts, removed)
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

  defp print_watch_actionable(rows, alerts, removed) do
    lines =
      watch_alert_lines(alerts) ++
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

  defp watch_stuck_lines(rows) do
    rows
    |> Enum.filter(& &1.stuck?)
    |> Enum.map(fn row -> "~ #{row.id} stuck · no activity for #{format_runtime(row.age_seconds)}" end)
  end

  defp watch_pr_ready_lines(rows) do
    rows
    |> Enum.filter(& &1.pr_ready?)
    |> Enum.map(fn row -> "> #{row.id} #{row.state} · needs review/merge" end)
  end

  defp watch_removed_lines(removed) do
    Enum.map(removed, fn id -> "- #{id} · left the board" end)
  end

  defp print_empty_selection(:pause, :all), do: IO.puts("aiur: no running agents")
  defp print_empty_selection(:resume, :all), do: IO.puts("aiur: no paused agents")

  defp print_orchestrator_status_error(error) do
    IO.puts(:stderr, Map.fetch!(%{timeout: "aiur: timed out while reading agent status", unavailable: "aiur: orchestrator is not running"}, error))
  end

  defp print_failure(action, status, reason) do
    IO.puts(:stderr, "aiur: failed to #{action} #{display_identifier(status)} (#{format_reason(reason)})")
  end

  defp target_matches?(status, target) do
    target = to_string(target)
    identifier = to_string(status.identifier || "")
    issue_id = to_string(status.issue_id || "")

    target == identifier or target == issue_id or String.ends_with?(identifier, "##{target}")
  end

  defp canonical_identifier(status) do
    to_string(status.identifier || status.issue_id)
  end

  defp pause_agent(identifier) do
    Application.get_env(:aiur, :agent_control_cli_pause_fun, &AgentChat.pause/1).(identifier)
  end

  defp resume_agent(identifier) do
    Application.get_env(:aiur, :agent_control_cli_resume_fun, &AgentChat.resume/1).(identifier)
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

  defp numeric_identifier?(identifier) when is_binary(identifier), do: Regex.match?(~r/^\d+$/, identifier)
  defp numeric_identifier?(_identifier), do: false

  defp activity_payload(message) do
    case map_value(message, ["payload", :payload]) do
      payload when is_map(payload) -> payload
      _ -> message
    end
  end

  defp result_verb(result), do: Map.fetch!(%{resumed: "resumed", started: "started"}, result)

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
        timeout: "orchestrator timed out"
      },
      reason,
      inspect(reason)
    )
  end

  defp exit_marker(code) do
    IO.puts("#{@exit_marker}#{code}")
    :ok
  end
end
