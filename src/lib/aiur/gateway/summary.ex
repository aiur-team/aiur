defmodule Aiur.Gateway.Summary do
  @moduledoc """
  The gateway summary (schema S6) served to the dashboard.

  Built from the same metadata the instance heartbeat publishes, so there is one grouping of projects.
  A value that cannot be read is `nil` (JSON `null`), never zero. `ready`, `focus_features` and `paused`
  have no producer yet and are always `nil`. `agents`, `next_queue` and `pending_decisions` are
  `%{state, value, observed_at, age_ms}`: `state` is `"unknown"` with a `nil` value when the store behind them could not be read.
  """

  @spec build(keyword()) :: map()
  def build(opts \\ []) do
    now = Keyword.get(opts, :now_fun, &DateTime.utc_now/0).()
    data = metadata(Keyword.get(opts, :metadata_fun, metadata_source()))
    running = data["agent_count"]
    max = data["agent_capacity"]
    observed_at = now |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    %{
      gateway_id: data["gateway_id"],
      gateway_label: data["gateway_label"],
      gateway_identity: data["gateway_identity"],
      observed_at: observed_at,
      age_ms: 0,
      connectivity: "online",
      workload: workload(running, max),
      capacity: %{max: max, running: running},
      projects: Enum.map(List.wrap(data["projects"]), &project(&1, observed_at)),
      executor_present: data["executor_present"]
    }
  end

  defp metadata_source, do: Application.get_env(:aiur, :gateway_summary_metadata, fn -> %{} end)

  defp metadata(fun) do
    case fun.() do
      %{"data" => data} when is_map(data) -> data
      _ -> %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp project(row, observed_at) do
    %{
      repo: row["repo"],
      observed_at: observed_at,
      age_ms: 0,
      focus_features: nil,
      running: row["running"],
      ready: nil,
      owned_tickets: row["owned_tickets"],
      paused: nil,
      agents: signal(row, "agents", observed_at),
      next_queue: signal(row, "next_queue", observed_at),
      pending_decisions: signal(row, "pending_decisions", observed_at)
    }
  end

  defp signal(row, key, observed_at) do
    case row[key] do
      nil -> %{state: "unknown", value: nil, observed_at: observed_at, age_ms: 0}
      value -> %{state: "known", value: value, observed_at: observed_at, age_ms: 0}
    end
  end

  defp workload(running, max) when is_integer(running) and is_integer(max) do
    cond do
      running >= max -> "saturated"
      running > 0 -> "active"
      true -> "idle"
    end
  end

  defp workload(_, _), do: nil
end
