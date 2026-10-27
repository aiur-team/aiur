defmodule Aiur.CommandsCLI.Printer do
  @moduledoc false

  @spec print_human(map()) :: :ok
  def print_human(envelope) do
    IO.puts("Commands captured #{get_in(envelope, ["snapshot", "captured_at"])}")
    Enum.each(envelope["sources"], fn {name, value} -> IO.puts("#{name}: #{value["state"]}; freshness #{value["freshness"]}") end)

    case get_in(envelope, ["data", "selected"]) do
      nil -> print_rows(get_in(envelope, ["data", "page", "decisions"]) || [], get_in(envelope, ["snapshot", "captured_at"]))
      decision -> print_detail(decision, get_in(envelope, ["snapshot", "captured_at"]), get_in(envelope, ["data", "history"]) || [])
    end

    page = get_in(envelope, ["data", "page"])
    if page["partial_results?"] || partial_rows?(page), do: IO.puts("Partial retained data; results may be incomplete or stale.")
    :ok
  end

  defp partial_rows?(page), do: Enum.any?(page["decisions"] || [], &(&1["freshness"] == "partial"))

  defp print_rows([], _captured_at), do: IO.puts("No Commands match this filter.")

  defp print_rows(rows, _captured_at) do
    IO.puts("ID  ROUTE  AGE  WHY  ASKS  TICKET|EXECUTOR")
    Enum.each(rows, &print_row/1)
  end

  defp print_row(row) do
    IO.puts("#{row["decision_id"]}  #{route(row["route_state"])}  #{duration(row["age_ms"])}  #{cause(row)}  #{row["short_label"] || row["question"]}  #{requester(row)}")
    if row["needs_you_ms"], do: IO.puts("  Needs you since: #{duration(row["needs_you_ms"])} ago")
    IO.puts("  Freshness: #{row["freshness"]}; observed: #{row["observed_at"]}")
  end

  defp route("with_executor"), do: "With Executor"
  defp route("with_human"), do: "Needs you"
  defp route("with_both"), do: "Needs you and Executor"
  defp route(_unknown), do: "?"

  defp duration(ms) when is_integer(ms), do: "#{div(ms, 1000)}s"
  defp duration(_unknown), do: "unknown"

  defp cause(row) do
    case row["escalations"] do
      [] -> "-"
      entries when is_list(entries) -> escalation_cause(List.last(entries))
      _unknown -> "?"
    end
  end

  defp escalation_cause(%{"cause" => cause}) when is_binary(cause) and cause != "", do: cause
  defp escalation_cause(_unknown), do: "?"

  defp requester(row) do
    if get_in(row, ["requester", "kind"]) == "executor",
      do: "Executor",
      else: ticket_label(get_in(row, ["ticket", "identifier"]) || "-", get_in(row, ["ticket", "title"]))
  end

  defp print_detail(decision, captured_at, history) do
    IO.puts("#{decision["decision_id"]} · #{decision["lifecycle"]} · blocking #{decision["blocking"]} · superseded #{decision["superseded?"]}")
    IO.puts(decision["question"])
    IO.puts("Route: #{route(decision["route_state"])}; Why: #{cause(decision)}")
    if decision["needs_you_ms"], do: IO.puts("Needs you since: #{duration(decision["needs_you_ms"])} ago")
    IO.puts("Freshness: #{decision["freshness"]}; observed: #{decision["observed_at"]}")
    IO.puts("Urgency: #{decision["urgency"]}")
    IO.puts("Origin: #{get_in(decision, ["source", "agent_id"]) || "unknown"}")
    IO.puts("Age: #{age(decision["created_at"], captured_at)}")
    IO.puts("Context: #{get_in(decision, ["context", "short"]) || "none"}")
    IO.puts("Consequence of delay: #{decision["consequence_of_delay"] || "none"}")
    IO.puts("Recommendation: #{recommendation(decision["recommendation"])}")

    Enum.each(decision["options"] || [], &print_option/1)

    print_relay(decision["answer"])
    print_history(Enum.filter(history, &(&1["decision_id"] == decision["decision_id"])))
  end

  defp print_option(option) do
    IO.puts("Option #{option["id"]}: #{option["label"]}#{if option["risk"], do: " (#{option["risk"]} risk)", else: ""}")
    IO.puts("  Description: #{option["description"] || "none"}")
    IO.puts("  Benefits: #{option["benefits"] || "none"}")
    IO.puts("  Drawbacks: #{option["drawbacks"] || "none"}")
  end

  defp age(created_at, captured_at) when is_binary(created_at) and is_binary(captured_at) do
    with {:ok, created_at, _offset} <- DateTime.from_iso8601(created_at),
         {:ok, captured_at, _offset} <- DateTime.from_iso8601(captured_at) do
      "#{max(DateTime.diff(captured_at, created_at), 0)}s"
    else
      _invalid -> "unknown"
    end
  end

  defp age(_created_at, _captured_at), do: "unknown"

  defp ticket_label(ticket, title) when is_binary(title) and title != "", do: "#{ticket} (#{title})"
  defp ticket_label(ticket, _title), do: ticket

  defp recommendation(%{"option_id" => option_id, "reason" => reason}), do: "#{option_id}: #{reason || "no rationale"}"
  defp recommendation(_recommendation), do: "none"

  defp print_relay(%{"relayed_by" => relayer, "operator_quote" => quote, "accepted_at" => at}) when is_binary(relayer) do
    IO.puts("Answer: answered by operator, relayed by #{relayer} at #{at}")
    IO.puts("Operator quote: #{quote}")
  end

  defp print_relay(_answer), do: :ok

  defp print_history([]), do: IO.puts("History: none")

  defp print_history(history) do
    IO.puts("History:")
    Enum.each(history, fn entry -> IO.puts("- #{entry["changed_at"] || "unknown"}: #{entry["change"] || "unknown"} · #{get_in(entry, ["actor", "label"]) || "unknown source"}") end)
  end
end
