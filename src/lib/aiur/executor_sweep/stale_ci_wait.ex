defmodule Aiur.ExecutorSweep.StaleCiWait do
  @moduledoc false

  @spec findings(map(), DateTime.t()) :: [map()]
  def findings(snapshot, now) do
    waiting =
      snapshot
      |> Map.get(:tickets, [])
      |> Enum.filter(&("ci-wait" in labels(&1)))
      |> Map.new(&{value(&1, :number, nil), date(value(&1, :ci_wait_since, value(&1, :updated_at, nil)))})

    snapshot
    |> Map.get(:pull_requests, [])
    |> Enum.flat_map(&finding(&1, waiting, now))
  end

  defp finding(pr, waiting, now) do
    issue_number = value(pr, :issue_number, nil)
    age = age_ms(Map.get(waiting, issue_number), now)
    required = value(pr, :required_checks, nil)
    pending? = is_list(required) and Enum.any?(required, &(value(&1, :conclusion, nil) in [nil, "pending", "in_progress", "queued"]))

    if Enum.all?(
         [
           Map.has_key?(waiting, issue_number),
           value(pr, :state, "open") == "open",
           value(pr, :ci_head_sha, nil) == value(pr, :head_sha, nil),
           value(pr, :ci_decision, nil) in [:passed, :failed, "passed", "failed"],
           is_integer(age),
           is_integer(age) and age > 2 * 60 * 60_000,
           is_list(required),
           not pending?
         ],
         & &1
       ) do
      [
        %{
          kind: "stale_ci_wait_without_pending_checks",
          priority: 2,
          age_ms: age,
          action: "Inspect the current PR head and move the ticket to human-review or rework.",
          message: "Ticket ##{issue_number} has been in ci-wait for #{duration(age)} with no pending required check.",
          issue_number: issue_number,
          pull_request: value(pr, :number, nil)
        }
      ]
    else
      []
    end
  end

  defp labels(ticket), do: ticket |> value(:labels, []) |> Enum.map(&if is_map(&1), do: value(&1, :name, ""), else: &1) |> Enum.map(&to_string/1) |> Enum.map(&String.trim_leading(&1, "agent:"))
  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp date(%DateTime{} = datetime), do: datetime
  defp date(ms) when is_integer(ms), do: DateTime.from_unix!(ms, :millisecond)

  defp date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp date(_), do: nil
  defp age_ms(%DateTime{} = timestamp, %DateTime{} = now), do: max(DateTime.diff(now, timestamp, :millisecond), 0)
  defp age_ms(_, _), do: nil

  defp duration(ms) do
    total_minutes = div(ms, 60_000)
    hours = div(total_minutes, 60)
    minutes = rem(total_minutes, 60)
    if hours > 0, do: "#{hours}h #{minutes}m", else: "#{minutes}m"
  end
end
