defmodule Aiur.Executor.Blockers do
  @moduledoc "Read-only Executor blockers with independent source availability."

  alias Aiur.{AlertFeed, Commands, Events, ExecutorBindings}
  alias Aiur.Commands.Requester
  alias Aiur.Config.Paths

  @type item :: %{kind: :command | :ask | :fleet, id: String.t(), title: String.t(), age_ms: non_neg_integer() | nil, link: String.t()}
  @type snapshot :: %{items: [item()], sources: map(), observed_at: DateTime.t()}

  @spec snapshot() :: snapshot()
  def snapshot, do: snapshot([])

  @doc false
  @spec snapshot(keyword()) :: snapshot()
  def snapshot(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    sources = [
      commands: fn -> commands(Keyword.get(opts, :commands_fun, fn -> read_commands(opts) end), now) end,
      asks: fn -> asks(Keyword.get(opts, :asks_fun, fn -> Commands.open_asks(Paths.repo_name()) end), now) end,
      fleet: fn -> fleet(Keyword.get(opts, :fleet_fun, fn -> AlertFeed.list(strict: true) end), now) end
    ]

    results = Task.async_stream(sources, fn {source, read} -> safe_read(source, read) end, timeout: Keyword.get(opts, :timeout, 2_000), on_timeout: :kill_task, max_concurrency: 3)

    {items, availability} =
      sources
      |> Enum.zip(results)
      |> Enum.reduce({[], %{}}, fn {{source, _read}, result}, {items, statuses} ->
        case result do
          {:ok, {:ok, found}} -> {items ++ found, Map.put(statuses, source, :ok)}
          {:ok, {:error, reason}} -> {items, Map.put(statuses, source, {:unavailable, reason})}
          {:exit, reason} -> {items, Map.put(statuses, source, {:unavailable, reason})}
        end
      end)

    %{items: Enum.sort_by(items, &{-(&1.age_ms || -1), &1.kind, &1.id}), sources: availability, observed_at: now}
  end

  defp safe_read(source, read) do
    read.()
  rescue
    error -> {:error, {:exception, error.__struct__}}
  catch
    :exit, {:noproc, _} when source == :commands -> {:error, :decision_store_down}
    kind, reason -> {:error, {kind, reason}}
  end

  defp read_commands(opts) do
    store = Keyword.get_lazy(opts, :store, &Commands.default_store/0)
    decisions = Commands.list_decisions(store)

    case Commands.query_counts(store: store) do
      {:ok, %{health: %{status: :available}}} -> {:ok, decisions}
      {:ok, %{health: %{reason: reason}}} -> {:error, reason}
    end
  end

  defp commands(read, now) do
    with {:ok, decisions} <- command_records(read.()) do
      {:ok, project_commands(decisions, now)}
    end
  end

  defp command_records(records) when is_list(records), do: {:ok, records}
  defp command_records(result), do: result

  defp project_commands(decisions, now) do
    decisions
    |> Enum.filter(fn decision -> Requester.executor?(decision) and Commands.open?(decision) end)
    |> Enum.map(fn decision ->
      item(:command, decision.decision_id, decision.short_label || decision.question, decision.created_at, "/commands/" <> URI.encode_www_form(decision.decision_id), now)
    end)
  end

  defp asks(read, now) do
    with {:ok, asks} <- read.() do
      {:ok, Enum.map(asks, &item(:ask, &1["id"], &1["title"], &1["created_at"], "/commands", now))}
    end
  end

  defp fleet(read, now) do
    patterns = Enum.filter(ExecutorBindings.patterns(), &String.starts_with?(&1, "system."))

    items =
      read.()
      |> Enum.filter(fn alert ->
        alert["needs_attention"] == true and
          Enum.any?(patterns, &Events.matches?(&1, alert["topic"]))
      end)
      |> Enum.map(fn alert -> item(:fleet, alert["topic"], alert["message"], alert["first_seen_at"] || alert["timestamp"], "/", now) end)

    {:ok, items}
  end

  defp item(kind, id, title, timestamp, link, now),
    do: %{kind: kind, id: id, title: title, age_ms: age(timestamp, now), link: link}

  defp age(%DateTime{} = timestamp, now), do: max(DateTime.diff(now, timestamp, :millisecond), 0)

  defp age(timestamp, now) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> age(parsed, now)
      _ -> nil
    end
  end

  defp age(_timestamp, _now), do: nil
end
