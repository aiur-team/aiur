defmodule AiurWeb.Build.ConversationEvents do
  @moduledoc """
  Builds the conversation's `ev` rows (what happened to the ticket) and places
  them among one page of transcript entries.

  Pure: the caller passes every read in. Log rows become timed history rows;
  the ticket row, merges and open Commands become current-fact rows: the
  dependency rows open the oldest page and the PR and state rows close the
  newest one, as the design's conversation does.
  """

  @log_limit 500
  @progress ~w(agent.progress agent.progress.checkin agent.progress.phase progress progress.checkin progress.phase)
  @dep_states %{"failed" => "failed", "not_planned" => "not planned", "closed" => "closed", "done" => "closed", "queued" => "queued", "open" => "open"}

  @type entry :: map()
  @type upper :: integer() | :infinity | :none

  @spec log_limit() :: pos_integer()
  def log_limit, do: @log_limit

  @doc "Maps the ticket's own event-log rows; unsupported topics are omitted."
  @spec from_log([map()], String.t(), %{optional(pos_integer()) => 0..100}) :: [entry()]
  def from_log(rows, identifier, percents) do
    prefix = "ticket." <> identifier <> "."

    Enum.flat_map(rows, fn row ->
      with topic when is_binary(topic) <- row[:topic],
           true <- String.starts_with?(topic, prefix),
           {:ok, at} <- millis(row[:ts]),
           {ev, label, pct} <- log_kind(String.replace_prefix(topic, prefix, ""), percents[row[:id]]) do
        [event("ev:log:#{row[:id]}", ev, label, sub: row[:summary], at: at, pct: pct)]
      else
        _ -> []
      end
    end)
  end

  @doc "Derives the shared conversation breakpoints from the ticket's persisted event history."
  @spec breakpoints([map()], String.t(), %{optional(pos_integer()) => 0..100}) :: [map()]
  def breakpoints(rows, identifier, percents), do: breakpoints(rows, identifier, percents, [])

  @spec breakpoints([map()], String.t(), %{optional(pos_integer()) => 0..100}, [map()]) :: [map()]
  def breakpoints(rows, identifier, percents, transcript) do
    relevant = relevant_rows(rows, identifier, percents)
    started = implementation_start(relevant, transcript)
    progress = progress_breakpoints(relevant)
    milestones = lifecycle_breakpoints(relevant)

    (started ++ progress ++ milestones)
    |> Enum.sort_by(&{&1.at, &1.source_id})
  end

  defp relevant_rows(rows, identifier, percents) do
    prefix = "ticket." <> identifier <> "."

    rows
    |> Enum.flat_map(&relevant_row(&1, prefix, percents))
    |> Enum.sort_by(&{&1.at, &1.id})
  end

  defp relevant_row(row, prefix, percents) do
    with topic when is_binary(topic) <- row[:topic],
         true <- String.starts_with?(topic, prefix),
         {:ok, at} <- millis(row[:ts]) do
      [%{id: row[:id], topic: String.replace_prefix(topic, prefix, ""), summary: row[:summary] || "", at: at, pct: percents[row[:id]] || row[:percent], review_state: row[:review_state]}]
    else
      _ -> []
    end
  end

  defp implementation_start(relevant, transcript) do
    start =
      Enum.find(relevant, &(&1.topic in ["agent.phase.work.start", "phase.work.start"])) ||
        Enum.find(relevant, &file_edit?/1) ||
        Enum.find_value(transcript, &transcript_file_edit/1)

    if start, do: [breakpoint(:implementation_started, "Implementation started", start)], else: []
  end

  defp progress_breakpoints(relevant) do
    Enum.flat_map([{25, :progress_25}, {50, :progress_50}, {75, :progress_75}], fn {threshold, kind} ->
      case Enum.find(relevant, &(&1.topic in @progress and is_integer(&1.pct) and &1.pct >= threshold)) do
        nil -> []
        row -> [breakpoint(kind, "Progress #{threshold}%", row)]
      end
    end)
  end

  defp lifecycle_breakpoints(relevant), do: Enum.flat_map(relevant, &lifecycle_breakpoint/1)

  defp lifecycle_breakpoint(%{topic: topic} = row) do
    cond do
      topic in ["agent.phase.work.end", "phase.work.end"] -> [breakpoint(:implementation_finished, "Implementation finished", row)]
      topic == "pr.opened" -> [breakpoint(:pr_opened, "PR opened", row)]
      topic in ["pr.review_comment", "pr.reviewed", "pr.review.posted"] -> review_breakpoint(row)
      topic == "pr.merged" -> [breakpoint(:pr_merged, "PR merged", row)]
      pause_label(topic, row.summary) -> [breakpoint(:pause, pause_label(topic, row.summary), row)]
      resume_topic?(topic) -> [breakpoint(:resumed, "Resumed", row)]
      true -> []
    end
  end

  defp review_breakpoint(row) do
    case review_detail(row) do
      nil -> []
      verdict -> [breakpoint(:pr_reviewed, "PR reviewed · " <> verdict, row)]
    end
  end

  defp breakpoint(kind, label, row), do: %{kind: kind, label: label, at: row.at, detail: clean(row.summary), source_id: row.id}

  defp file_edit?(%{topic: topic, summary: summary}) do
    topic in ["agent.file.edit", "agent.file_edit", "agent.tool_call"] and
      (String.contains?(String.downcase(summary), "edit") or String.contains?(String.downcase(summary), "write"))
  end

  defp transcript_file_edit(%{k: "diff", id: id, at: at} = entry) when is_integer(at),
    do: %{id: id, at: at, summary: entry[:file] || "", topic: "transcript.file.edit"}

  defp transcript_file_edit(%{k: "tool", id: id, at: at} = entry) when is_integer(at) do
    if entry[:name] in ["Edit", "Write", "edit", "write", "apply_patch"],
      do: %{id: id, at: at, summary: entry[:arg] || entry[:name], topic: "transcript.file.edit"}
  end

  defp transcript_file_edit(_entry), do: nil

  defp review_detail(%{review_state: "APPROVED"}), do: "approved"
  defp review_detail(%{review_state: "CHANGES_REQUESTED"}), do: "changes requested"
  defp review_detail(%{review_state: state}) when is_binary(state), do: nil

  defp review_detail(%{summary: summary}) do
    case Regex.run(~r/\b(approved|changes requested)\b/i, summary) do
      [_, verdict] -> String.downcase(verdict)
      _ -> nil
    end
  end

  defp pause_label(topic, summary) do
    detail = clean(summary)

    cond do
      topic == "agent.pause.request" -> if(detail == "", do: "Pause requested", else: "Pause requested · " <> detail)
      topic in ["agent.paused", "agent.paused.resolved"] -> if(detail == "", do: "Paused", else: "Paused · " <> detail)
      String.contains?(topic, "parked") -> if(detail == "", do: "Parked", else: "Parked · " <> detail)
      true -> nil
    end
  end

  defp resume_topic?(topic), do: topic in ["agent.unblocked", "agent.unpaused", "agent.auto_resumed"]

  defp log_kind(topic, pct) when topic in @progress and is_integer(pct), do: {"prog", "Progress · #{pct}%", pct}
  defp log_kind(topic, _pct) when topic in @progress, do: {"prog", "Progress updated", nil}
  defp log_kind("pr.opened", _), do: {"pr", "Opened PR", nil}
  defp log_kind("pr.ready_for_review", _), do: {"pr", "PR ready for review", nil}
  defp log_kind("branch.push", _), do: {"commit", "Commit pushed", nil}
  defp log_kind("agent.phase.review.start", _), do: {"review", "Review started", nil}
  defp log_kind("agent.phase.review.end", _), do: {"review", "Review complete", nil}
  defp log_kind("agent.blocked", _), do: {"dep", "Blocked", nil}
  defp log_kind("agent.unblocked", _), do: {"dep", "Unblocked", nil}
  defp log_kind("agent.pause.request", _), do: {"you", "Agent asked to pause", nil}
  defp log_kind("phase.review.start", _), do: {"review", "Review started", nil}
  defp log_kind("phase.review.end", _), do: {"review", "Review complete", nil}
  defp log_kind("blocked", _), do: {"dep", "Blocked", nil}
  defp log_kind("unblocked", _), do: {"dep", "Unblocked", nil}
  defp log_kind("pause.request", _), do: {"you", "Agent asked to pause", nil}
  defp log_kind(_topic, _), do: nil

  @doc """
  Percent per event id, from an available history snapshot's progress entries;
  a percent is never borrowed from another event.
  """
  @spec progress_index(term()) :: %{optional(pos_integer()) => 0..100}
  def progress_index({:ok, %{health: :available, entries: entries}}) when is_list(entries) do
    for %{kind: :progress, event_id: id, details: %{percent: pct}} <- entries, is_integer(id), pct in 0..100, into: %{}, do: {id, pct}
  end

  def progress_index(_snapshot), do: %{}

  @doc """
  Current-fact rows (rows 6–16). `facts` carries `:deps` (dependency rows by id),
  `:merges` (a list, or `:unavailable`), `:decisions` (`{:ok, list}` or
  `:unavailable`), `:logged_events` (mapped history rows), `:pause` (the pause
  reason), `:by_you_at` and `:repository` (`"owner/name"`).
  """
  @spec current_facts(map(), map()) :: %{deps: [entry()], tail: [entry()]}
  def current_facts(row, facts) do
    merges = if is_list(facts[:merges]), do: facts[:merges], else: []
    repo = facts[:repository]
    deps = facts[:deps] || %{}
    dep_rows = for id <- row_value(row, :deps) || [], dep = deps[id], is_map(dep), is_integer(dep["num"]), do: dep_event(dep, merge_for(merges, dep["id"], repo))
    pr = pr_event(row, merge_for(merges, row_value(row, :id), repo))
    pr_rows = if match?(%{ev: "pr"}, pr) and logged_pr_open?(facts[:logged_events]), do: [], else: List.wrap(pr)
    tail = pr_rows ++ command_events(row, facts[:decisions], repo) ++ List.wrap(state_event(row, facts))
    %{deps: dep_rows, tail: tail}
  end

  defp logged_pr_open?(events) when is_list(events), do: Enum.any?(events, &match?(%{ev: "pr", label: "Opened PR"}, &1))
  defp logged_pr_open?(_events), do: false

  defp dep_event(dep, merge) do
    merged? = get_in(dep, ["pr", "state"]) == "merged"
    label = "Dependency ##{dep["num"]}" <> dep_state(dep, merged?)
    at = if merged?, do: (merge && millis!(merge.merged_at)) || dep["end"]
    event("ev:dep:#{dep["id"]}", "dep", label, sub: dep["title"], at: at, go: dep["id"])
  end

  defp dep_state(_dep, true), do: " merged"
  defp dep_state(%{"sec" => "now"}, _), do: " in progress"
  defp dep_state(%{"status" => "running"}, _), do: " in progress"

  defp dep_state(dep, _) do
    case @dep_states[dep["status"]] do
      nil -> " · state unknown"
      state -> " " <> state
    end
  end

  defp merge_for(_merges, id, _repo) when is_nil(id), do: nil
  defp merge_for(_merges, _id, nil), do: nil
  defp merge_for(merges, id, repo), do: Enum.find(merges, &(&1.ticket_id == id and is_binary(&1.repository) and String.downcase(&1.repository) == String.downcase(repo)))

  defp pr_event(_row, %{number: num} = merge) when is_integer(num), do: event("ev:merge:#{num}", "merge", "Merged PR ##{num}", at: millis!(merge.merged_at))

  defp pr_event(row, nil) do
    pr = row_value(row, :pr)
    num = is_map(pr) && row_value(pr, :num)
    state = is_map(pr) && row_value(pr, :state)

    if is_integer(num) do
      case {state, row_value(row, :status)} do
        {"merged", _} -> event("ev:merge:#{num}", "merge", "Merged PR ##{num}", at: row_value(row, :end))
        {"open", _} -> event("ev:pr:#{num}", "pr", "Opened PR ##{num}", sub: row_value(row, :title))
        {"closed", "failed"} -> event("ev:fail:pr:#{num}", "fail", "PR ##{num} closed", at: row_value(row, :end))
        _ -> nil
      end
    end
  end

  defp pr_event(_row, _merge), do: nil

  defp command_events(row, {:ok, decisions}, repo) do
    case for(d <- decisions, same_repository?(d, repo), do: event("ev:cmd:#{d.id}", "cmd", "Asked a blocking question", sub: "waiting for your answer", at: millis!(d.created_at))) do
      [] -> command_state(row)
      rows -> rows
    end
  end

  defp command_events(row, _unavailable, _repo), do: command_state(row)

  defp command_state(row), do: if(agent_state(row) == "command", do: [event("ev:state:command", "cmd", "Asked a blocking question")], else: [])

  defp same_repository?(decision, repo) do
    case get_in(decision.ticket, [:url]) do
      nil -> true
      url when is_binary(url) and is_binary(repo) -> String.contains?(String.downcase(url), "github.com/" <> String.downcase(repo) <> "/")
      _ -> false
    end
  end

  defp state_event(row, facts) do
    case agent_state(row) do
      "paused" -> event("ev:state:paused", "you", if(facts[:pause] == :operator_pause, do: "Paused by you", else: "Paused"), at: facts[:by_you_at])
      "parked" -> event("ev:state:parked", "you", parked(facts[:pause]))
      "error" -> event("ev:state:error", "fail", "Error")
      "retries" -> event("ev:state:retries", "fail", "Retries exhausted")
      _ -> nil
    end
  end

  defp parked(:usage_limit_exhausted), do: "Parked · waiting for model capacity"
  defp parked(:github_budget_hold), do: "Parked · GitHub budget hold"
  defp parked(_reason), do: "Parked"

  defp row_value(row, key), do: Map.get(row, key, Map.get(row, Atom.to_string(key)))

  @spec agent_state(map()) :: String.t() | nil
  def agent_state(row) do
    with agent when is_map(agent) <- row_value(row, :agent) do
      row_value(agent, :state)
    end
  end

  @doc "The live-only \"Resumed\" row (row 17) when a change moves the open ticket from paused or parked to active."
  @spec resumed(String.t() | nil, String.t() | nil, integer() | nil) :: entry() | nil
  def resumed(from, "active", now) when from in ["paused", "parked"] and is_integer(now), do: event("ev:resume:#{now}", "commit", "Resumed", at: now)
  def resumed(_from, _to, _now), do: nil

  @doc "One `sys` row in C11-T03's markup."
  @spec sys(String.t(), String.t(), integer() | nil) :: entry()
  def sys(id, text, at), do: %{id: id, k: "sys", at: at, text: text}

  @doc """
  Places events on one page. Log windows are contiguous (`lo ≤ at < upper`), so
  no event falls between two pages. The oldest page (`more?` false) takes every
  remaining event and opens with `lead` (the dependency rows); a first view
  closes with `tail`. Returns the page and the next `upper`.
  """
  @spec page([entry()], [entry()], upper(), boolean(), %{lead: [entry()], tail: [entry()]}) :: {[entry()], upper()}
  def page(entries, log, upper, more?, %{lead: lead, tail: tail}) do
    lo = entries |> Enum.map(& &1[:at]) |> Enum.filter(&is_integer/1) |> Enum.min(fn -> nil end)
    {window, upper} = window(log, lo, upper, more?)
    body = merge(entries, window)
    body = if more?, do: body, else: lead ++ body
    {body ++ tail, upper}
  end

  @spec window([entry()], integer() | nil, upper(), boolean()) :: {[entry()], upper()}
  def window(log, _lo, upper, false), do: {Enum.filter(log, &below?(&1, upper)), :none}
  def window(log, nil, :infinity, true), do: {log, :none}
  def window(_log, nil, upper, true), do: {[], upper}
  def window(log, lo, upper, true), do: {Enum.filter(log, &(&1.at >= lo and below?(&1, upper))), lo}

  @doc "Log events already inside the pages sent so far (`at ≥ upper`)."
  @spec shown?(entry(), upper()) :: boolean()
  def shown?(_event, :none), do: true
  def shown?(%{at: at}, upper) when is_integer(upper) and is_integer(at), do: at >= upper
  def shown?(_event, _upper), do: false

  defp below?(_event, :infinity), do: true
  defp below?(_event, :none), do: false
  defp below?(%{at: at}, upper), do: at < upper

  # Events go before the first later-timed entry; on a tie the entry comes first; untimed entries keep their place.
  defp merge(entries, events) do
    {out, rest} =
      Enum.reduce(entries, {[], Enum.sort_by(events, &order/1)}, fn entry, {out, pending} ->
        {earlier, later} = if is_integer(entry[:at]), do: Enum.split_while(pending, &(&1.at < entry.at)), else: {[], pending}
        {[entry | Enum.reverse(earlier, out)], later}
      end)

    Enum.reverse(out, rest)
  end

  defp order(%{at: at, id: "ev:log:" <> id}), do: {at, String.to_integer(id)}
  defp order(%{at: at}), do: {at, 0}

  defp event(id, ev, label, opts \\ []) do
    base = %{id: id, k: "ev", ev: ev, label: clean(label), at: opts[:at]}
    sub = if is_binary(opts[:sub]), do: clean(opts[:sub]), else: ""

    base
    |> then(&if(sub == "", do: &1, else: Map.put(&1, :sub, sub)))
    |> then(&if(is_binary(opts[:go]), do: Map.put(&1, :go, opts[:go]), else: &1))
    |> then(&if(is_integer(opts[:pct]), do: Map.put(&1, :pct, opts[:pct]), else: &1))
  end

  # Raw text (C3-T02): never HTML-escaped here; the adapter has already redacted agent-written summaries.
  defp clean(text), do: text |> String.replace_invalid("") |> String.slice(0, 8_000)

  @spec millis(term()) :: {:ok, integer()} | :error
  def millis(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, time, _} -> {:ok, DateTime.to_unix(time, :millisecond)}
      _ -> :error
    end
  end

  def millis(_ts), do: :error

  defp millis!(%DateTime{} = time), do: DateTime.to_unix(time, :millisecond)
  defp millis!(_time), do: nil
end
