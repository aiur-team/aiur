defmodule Aiur.BuildOrder.Published.Progress do
  @moduledoc """
  Progress records for `build-order.v1`.

  Counts are nullable so a reader must consult `status` before a total. An
  unavailable tracker publishes `null` counts with a reason and a partially read
  generation publishes counts flagged `stale`; neither ever becomes a fabricated
  zero or a 0% bar.
  """

  @open_statuses ["open", "running", "queued", "planned"]
  @done_statuses ["done"]
  @failed_statuses ["failed"]

  @type record :: map()

  @spec aggregate([map()], keyword()) :: record()
  def aggregate(tickets, opts \\ []) do
    reason = Keyword.get(opts, :reason)
    observed_at = Keyword.get(opts, :observed_at)

    cond do
      Keyword.get(opts, :unavailable?, false) ->
        unknown(reason || "provider_unavailable", observed_at)

      Enum.any?(tickets, &(&1["status"] == "unknown")) ->
        counts(tickets, "stale", reason || "partial_read", observed_at)

      true ->
        counts(tickets, "known", nil, observed_at)
    end
  end

  @spec unknown(String.t(), term()) :: record()
  def unknown(reason, observed_at \\ nil) do
    %{
      "status" => "unknown",
      "total" => nil,
      "done" => nil,
      "open" => nil,
      "failed" => nil,
      "percent" => nil,
      "by_status" => nil,
      "observed_at" => observed_at_value(observed_at),
      "reason" => reason
    }
  end

  defp counts(tickets, status, reason, observed_at) do
    frequencies = Enum.frequencies_by(tickets, & &1["status"])
    total = length(tickets)
    done = count(frequencies, @done_statuses)
    failed = count(frequencies, @failed_statuses)
    open = count(frequencies, @open_statuses)
    percent = if total > 0, do: round(done / total * 100), else: 0

    %{
      "status" => status,
      "total" => total,
      "done" => done,
      "open" => open,
      "failed" => failed,
      "percent" => percent,
      "by_status" => frequencies,
      "observed_at" => observed_at_value(observed_at),
      "reason" => reason
    }
  end

  defp count(frequencies, statuses),
    do: statuses |> Enum.map(&Map.get(frequencies, &1, 0)) |> Enum.sum()

  defp observed_at_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp observed_at_value(value) when is_binary(value), do: value
  defp observed_at_value(_value), do: nil
end
