defmodule Aiur.VoiceConverse.Host.BriefingCard do
  @moduledoc false

  alias Aiur.AgentStatusNote
  alias Aiur.VoiceConverse.Host.{CommandSource, Worker}
  alias VoiceConverse.Briefing

  @spec build(map(), Worker.t(), keyword(), DateTime.t()) :: Briefing.t()
  def build(row, target, opts, status_observed_at) do
    note = status_note(target, opts)
    note_at = note_observed_at(note) || status_observed_at

    %Briefing{
      summary: optional_field(row[:state] && to_string(row[:state]), status_observed_at, 30),
      current_task: field(note_value(note, "doing") || "No note from the agent yet", note_at, 600),
      next_steps: optional_list_field(note_value(note, "next"), note_at, 600),
      waiting_on: optional_field(note_value(note, "waiting_on"), note_at, 600),
      questions: optional_list_field(note_value(note, "asks"), note_at, 600),
      extra: card_lines(row, note, target, opts, status_observed_at),
      gaps: if(note == :none, do: ["No note from the agent yet."], else: [])
    }
  end

  defp status_note(%Worker{identity: identity}, opts) do
    note_opts = if root = Keyword.get(opts, :status_note_root), do: [root: root], else: []

    case AgentStatusNote.latest(identity.identifier, note_opts) do
      {:ok, note} -> note
      :none -> :none
    end
  end

  defp card_lines(row, note, target, opts, observed_at) do
    history = Aiur.IssueLog.history(target.identity.identifier, 100)
    status_lines(row, note, observed_at) ++ note_lines(note, observed_at) ++ conversation_lines(row, history, target, opts, observed_at) ++ recent_milestones(history, observed_at)
  rescue
    _error -> [extra("Status", "Some briefing data is unavailable", observed_at)]
  end

  defp status_lines(row, note, observed_at) do
    ci = row[:ci_result] || %{}

    [
      extra("Phase", row[:activity_stage] || "not reported", observed_at),
      extra("Progress", progress(row), observed_at),
      extra("PR", note_value(note, "pr") || value(ci, :pr_number) || "not reported", observed_at),
      extra("CI", ci_summary(ci), observed_at),
      extra("Review", value(ci, :review_decision) || "not reported", observed_at),
      extra("Listener mode", listener_mode(row), observed_at)
    ]
  end

  defp note_lines(note, observed_at), do: [extra("Why", note_value(note, "why") || "not reported", observed_at), extra("Risks", note_value(note, "risks") || "not reported", observed_at)]

  defp conversation_lines(row, history, target, opts, observed_at) do
    commands = open_commands(target, opts)
    [extra("Last operator message", last_operator_message(row, history, opts), observed_at), extra("Open Commands", Enum.join(commands, "; ") |> empty_as("none"), observed_at)]
  end

  defp progress(row) do
    case {row[:progress_percent], row[:progress_freshness]} do
      {percent, freshness} when is_number(percent) and freshness in [:fresh, :stale] -> "#{percent}% (#{freshness})"
      _ -> "not reported"
    end
  end

  defp listener_mode(row) do
    case get_in(row, [:listener, :effective]) do
      mode when is_atom(mode) -> Atom.to_string(mode)
      mode when is_binary(mode) -> mode
      _ -> "not reported"
    end
  end

  defp open_commands(target, opts) do
    case CommandSource.open(target, opts) do
      {:ok, commands} ->
        commands
        |> Enum.take(3)
        |> Enum.map(fn command -> "#{command.question} (#{Enum.map_join(command.options, ", ", &option_label/1)})" end)

      _ ->
        []
    end
  end

  defp recent_milestones(history, observed_at) do
    history
    |> Enum.filter(&(&1[:role] == :alert))
    |> Enum.take(-5)
    |> Enum.map(&extra("Milestone", &1[:body] || "", observed_at))
  end

  defp last_operator_message(row, history, opts) do
    case latest_operator_message(row, history) do
      {id, text} when is_integer(id) and is_binary(text) ->
        status_reader = Keyword.get(opts, :delivery_status, &Aiur.AgentChat.delivery_status/2)
        "#{excerpt(text, 120)} (#{delivery_label(status_reader.(id, 1_000))})"

      _ ->
        "not reported"
    end
  end

  defp latest_operator_message(row, history) do
    case List.last(row[:pending_operator_messages] || []) do
      %{id: id, text: text} when is_integer(id) and is_binary(text) ->
        {id, text}

      _ ->
        history
        |> Enum.reverse()
        |> Enum.find_value(fn
          %{role: :user, body: body, payload: %{operator_message: %{request_id: id}}} when is_integer(id) -> {id, body}
          _ -> nil
        end)
    end
  end

  defp ci_summary(%{decision: decision, observed_at_ms: observed_at_ms}) when is_atom(decision) and is_integer(observed_at_ms) do
    age_ms = max(System.monotonic_time(:millisecond) - observed_at_ms, 0)
    result = Atom.to_string(decision)
    if age_ms > 120_000, do: "#{result} (as of #{age(age_ms)})", else: result
  end

  defp ci_summary(%{"decision" => decision}) when is_binary(decision), do: decision
  defp ci_summary(%{decision: decision}) when is_atom(decision), do: Atom.to_string(decision)
  defp ci_summary(_result), do: "not reported"

  defp age(age_ms) when age_ms < 60_000, do: "#{div(age_ms, 1_000)} sec ago"
  defp age(age_ms), do: "#{div(age_ms, 60_000)} min ago"

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp extra(title, text, observed_at), do: %{title: title, text: to_string(text), observed_at: observed_at}
  defp field(nil, _observed_at, _max_age_s), do: nil
  defp field(value, observed_at, max_age_s), do: %{value: value, observed_at: observed_at, max_age_s: max_age_s}
  defp optional_field(nil, _observed_at, _max_age_s), do: nil
  defp optional_field(value, observed_at, max_age_s), do: field(value, observed_at, max_age_s)
  defp optional_list_field(nil, _observed_at, _max_age_s), do: nil
  defp optional_list_field(value, observed_at, max_age_s), do: field([value], observed_at, max_age_s)
  defp note_value(%{} = note, key), do: Map.get(note, key)
  defp note_value(_note, _key), do: nil

  defp note_observed_at(%{"observed_at" => value}), do: parse_datetime(value)
  defp note_observed_at(_note), do: nil
  defp parse_datetime(%DateTime{} = at), do: at

  defp parse_datetime(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil
  defp delivery_label({:ok, status}) when status in [:pending, :delivered, :consumed], do: Atom.to_string(status)
  defp delivery_label(_status), do: "status unavailable"
  defp option_label(%{label: label}), do: to_string(label)
  defp option_label(%{"label" => label}), do: to_string(label)
  defp option_label(label) when is_binary(label), do: label
  defp option_label(option), do: inspect(option)

  defp excerpt(text, limit) do
    clipped = text |> String.to_charlist() |> Enum.take(limit) |> List.to_string()
    clipped <> if(byte_size(clipped) < byte_size(text), do: "…", else: "")
  end

  defp empty_as("", fallback), do: fallback
  defp empty_as(text, _fallback), do: text
end
