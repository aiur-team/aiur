defmodule Aiur.BuildOrder.Index do
  @moduledoc "Shared build-home join and changes; all input reads are local projections."
  alias Aiur.BuildOrder.{EpicOverrides, Features, History, NotQueued}
  alias Aiur.BuildOrder.Index.{Catalogue, Pages, Parts, Rows, Sources}
  @topic "build-home:index"
  @blocks ~w(epics features order counts sources history_meta repo)a

  @spec assemble(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def assemble(parts, opts \\ []) do
    with {:ok, general} <- Catalogue.general(parts) do
      parts = Map.put(parts, :resolved_history, Map.merge(Rows.open_history(parts), Rows.history(parts)))
      now = Keyword.get(opts, :now, System.system_time(:millisecond))
      {all, undated} = Rows.build(parts, general)
      catalogue = Catalogue.build(parts, general, all, now)
      sources = Sources.build(parts, now)
      complete? = sources.history.state not in ["unavailable", "incomplete"]
      counts = if complete?, do: counts(all, catalogue.order)
      hist = all |> Map.values() |> Enum.filter(&(&1.sec == "hist")) |> Enum.sort_by(&{&1.end, &1.id})
      available? = sources.history.state != "unavailable"

      {:ok,
       Map.merge(catalogue, %{
         all: all,
         hist: hist,
         counts: counts,
         sources: sources,
         history_meta: %{total: if(available?, do: length(hist)), undated: if(available?, do: undated)},
         repo: repository(parts),
         now: now
       })}
    end
  end

  @doc "Epic resolver inputs for one ticket; failed inputs remain unknown."
  @spec resolver_context(map(), pos_integer()) :: map()
  def resolver_context(parts, number), do: Rows.resolver_context(parts, number)

  @spec diff(map(), map()) :: map()
  def diff(old, new) do
    upsert = new.all |> Enum.reject(fn {id, row} -> old.all[id] == row end) |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.id)
    remove = old.all |> Map.keys() |> Enum.reject(&Map.has_key?(new.all, &1)) |> Enum.sort()
    set = @blocks |> Enum.filter(&changed?(&1, old, new)) |> Map.new(&{&1, new[&1]})
    %{upsert: upsert, remove: remove, set: set}
  end

  @doc "Zone-independent window input, sorted once per index generation."
  @spec base(map()) :: map()
  defdelegate base(index), to: Pages
  @spec window(map(), String.t(), integer()) :: map()
  defdelegate window(base, zone, now), to: Pages
  @spec earlier(map(), integer(), String.t(), integer()) :: {:ok, map()} | {:error, :invalid_params}
  def earlier(index, before, zone, days), do: Pages.earlier(index, before, zone, days)
  @spec local_midnight(Date.t(), String.t()) :: integer()
  defdelegate local_midnight(date, zone), to: Pages
  @spec read_core_parts(MapSet.t() | :all, keyword()) :: map()
  defdelegate read_core_parts(dirty, opts), to: Parts, as: :read

  @spec safe_read(atom(), (-> term())) :: term()
  defdelegate safe_read(part, fun), to: Parts, as: :safe

  @doc false
  @spec planning_context(map(), MapSet.t()) :: map()
  def planning_context(parts, active) do
    prefix =
      case parts[:settings] do
        {:ok, settings} -> settings.tracker.github.label_prefix
        _ -> "agent"
      end

    history = %{rows: Map.merge(Rows.open_history(parts), Rows.history(parts))}

    nq =
      case parts[:open] do
        %Aiur.OpenTicketSource.Snapshot{} = open ->
          safe_read(:not_queued, fn -> NotQueued.build(open, parts[:queue], active: active, label_prefix: prefix) end)

        {:error, reason} ->
          %{state: :unavailable, reasons: [open_failure_reason(reason)], observed_at: nil, truncated?: false, skipped: 0, rows: []}

        _ ->
          %{state: :unavailable, reasons: [:open_tickets_unavailable], observed_at: nil, truncated?: false, skipped: 0, rows: []}
      end

    %{history_snapshot: {:ok, history}, todo_label: prefix <> ":todo", not_queued: nq}
  end

  defp open_failure_reason(:timeout), do: :open_tickets_timeout
  defp open_failure_reason(_reason), do: :open_tickets_read_failed

  @spec subscribe_sources() :: :ok | {:error, term()}
  def subscribe_sources do
    subscribers = [
      &History.subscribe/0,
      &Features.subscribe/0,
      &EpicOverrides.subscribe/0,
      &Aiur.BuildProgress.subscribe/0,
      &Aiur.OpenTicketSource.subscribe/0,
      &Aiur.TicketActivity.subscribe/0,
      &Aiur.AgentPubSub.subscribe_running/0,
      fn -> Phoenix.PubSub.subscribe(Aiur.PubSub, "build_queue:changed") end
    ]

    Enum.reduce_while(subscribers, :ok, fn subscribe, :ok ->
      case subscribe.() do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Aiur.PubSub, @topic)
  @spec broadcast(map()) :: :ok
  def broadcast(changes) do
    if Process.whereis(Aiur.PubSub), do: Phoenix.PubSub.broadcast(Aiur.PubSub, @topic, {:build_changes, changes})
    :ok
  end

  defp counts(all, order), do: Enum.reduce(all, Map.new(order, &{&1, 0}), fn {_id, row}, acc -> Map.update!(acc, row.epic, &(&1 + 1)) end)

  defp changed?(:sources, old, new), do: Map.delete(old.sources, :index) != Map.delete(new.sources, :index)
  defp changed?(key, old, new), do: old[key] != new[key]

  defp repository(%{repository: {:ok, {owner, repo}}}), do: %{url: "https://github.com/#{owner}/#{repo}/"}
  defp repository(_parts), do: nil
end
