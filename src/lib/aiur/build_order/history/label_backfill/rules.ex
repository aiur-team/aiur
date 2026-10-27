defmodule Aiur.BuildOrder.History.LabelBackfill.Rules do
  @moduledoc "Pure eligibility, request pacing and error policy for optional history writes."

  @spec eligible(map(), map() | :unknown, map()) :: term()
  def eligible(candidate, row, settings) do
    cond do
      settings[:registry_unknown] -> {:defer, :registry_unknown}
      candidate.kind == :feature and candidate[:projection] != :held_backfill -> :not_item
      candidate.confirmed != true -> {:skip, :unconfirmed}
      row == :unknown or settings[:history_state] != :healthy -> {:defer, :history_unknown}
      true -> eligible_row(candidate, row)
    end
  end

  defp eligible_row(candidate, row) do
    cond do
      row.lifecycle.state == :unknown -> {:defer, :state_unknown}
      row.lifecycle.state != :closed -> {:skip, :open}
      row.labels == :unknown -> {:defer, :labels_unknown}
      Enum.any?(row.labels, &(String.downcase(&1) == String.downcase(candidate.label))) -> {:done, :already_present}
      true -> :write
    end
  end

  @spec max_per_hour(non_neg_integer()) :: non_neg_integer()
  def max_per_hour(0), do: 125
  def max_per_hour(limit), do: div(limit, 2)

  @spec window_allows?([DateTime.t()], pos_integer(), DateTime.t()) :: boolean()
  def window_allows?(window, limit, now), do: length(recent(window, now)) < limit

  @spec recent([DateTime.t()], DateTime.t()) :: [DateTime.t()]
  def recent(window, now), do: Enum.filter(window, &(DateTime.diff(now, &1, :millisecond) < 3_600_000))

  @spec on_result(term(), DateTime.t()) :: term()
  def on_result(:ok, _now), do: :written
  def on_result({:error, reason}, now), do: error(reason, now)

  defp error({:github, :local_hold, details}, now), do: {:hold, hold(details[:hold], now)}
  defp error({:github, :transport, %{reason: {:aiur, :locally_held, details}}}, now), do: {:hold, hold(details, now)}

  defp error({:github, :rate_limited, details}, now) do
    until =
      case details do
        %{retry_after: seconds} when is_integer(seconds) and seconds > 0 -> DateTime.add(now, seconds)
        %{reset_at: at} when is_binary(at) -> parse_reset(at, now)
        _ -> fallback(now)
      end

    {:hold, until}
  end

  defp error({:github_api_status, status, _}, now) when status in [401, 403, 429],
    do: if(status == 429, do: {:hold, fallback(now)}, else: {:stop, if(status == 401, do: :auth, else: :forbidden)})

  defp error({:github_api_request, {:aiur, :locally_held, details}}, now), do: {:hold, hold(details, now)}
  defp error({:github_api_request, :github_budget_broker_timeout}, now), do: {:hold, fallback(now)}
  defp error({:github, :auth, _}, _now), do: {:stop, :auth}
  defp error({:github, :http, %{status: 403}}, _now), do: {:stop, :forbidden}
  defp error({:github, :http, %{status: status}}, _now) when status in [404, 410], do: {:failed, :gone}
  defp error(:unsupported, _now), do: {:stop, :unsupported}
  defp error(reason, _now), do: {:retry, inspect(reason, limit: 20) |> String.slice(0, 500)}

  defp hold(%{reset_at: %DateTime{} = at}, now), do: future(at, now)
  defp hold(_, now), do: fallback(now)

  defp parse_reset(at, now) do
    case DateTime.from_iso8601(at) do
      {:ok, parsed, _} -> future(parsed, now)
      _ -> fallback(now)
    end
  end

  defp future(at, now), do: if(DateTime.compare(at, now) == :gt, do: at, else: fallback(now))
  defp fallback(now), do: DateTime.add(now, 900)
end
