defmodule Aiur.Gateway.Capacity do
  @moduledoc """
  Machine-wide agent slots shared by every project's orchestrator.

  A ledger of issue ids per project, mirrored to ETS so `headroom/1` is a plain
  read on the dispatch hot path. `acquire/2` takes a slot when a worker starts;
  `sync/2` replaces a project's holders with the orchestrator's own truth each
  tick, which releases finished work. The broker monitors each holder process, so
  a crashed orchestrator returns its grants at once. Grants are first-come.

  The ceiling is `--max-agents` when given, else `capacity.max_agents` in
  `~/.aiur/machine`; unset means no machine cap. `projects[].max_agents` bounds
  one project. Every call degrades to "no limit" when the broker is not running.
  """
  use GenServer

  require Logger

  alias Aiur.Machine.Settings

  @table :aiur_gateway_capacity
  @call_timeout 1_000

  @type project_id :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Slots a project may still take now: `:infinity` when nothing bounds it (no broker, unknown project)."
  @spec headroom(project_id()) :: :infinity | non_neg_integer()
  def headroom(project_id) do
    with [{_, held, max}] <- :ets.lookup(@table, project_id),
         [{:machine, total, ceiling}] <- :ets.lookup(@table, :machine) do
      [bound(ceiling, total), bound(max, held)] |> Enum.min()
    else
      _ -> :infinity
    end
  rescue
    ArgumentError -> :infinity
  end

  @doc "Takes a slot for `issue_id`; idempotent. A missing or slow broker grants it."
  @spec acquire(project_id(), term()) :: :ok | {:error, :machine_full | :project_full}
  def acquire(project_id, issue_id), do: call({:acquire, project_id, issue_id, self()}, :ok)

  @doc "Replaces the project's holders with `issue_ids`, the issues now occupying slots."
  @spec sync(project_id(), Enumerable.t()) :: :ok
  def sync(project_id, issue_ids), do: call({:sync, project_id, MapSet.new(issue_ids), self()}, :ok)

  @spec snapshot() :: %{ceiling: pos_integer() | nil, held: non_neg_integer(), projects: [map()]} | :unavailable
  def snapshot, do: call(:snapshot, :unavailable)

  # Numbers sort before atoms, so `Enum.min/1` over these picks the tighter bound.
  defp bound(nil, _held), do: :infinity
  defp bound(limit, held), do: max(limit - held, 0)

  # Fail open: a stuck broker must not stop dispatch, so a missed ceiling beats a halted fleet.
  defp call(request, fallback) do
    GenServer.call(__MODULE__, request, @call_timeout)
  catch
    :exit, reason ->
      Logger.warning("Gateway capacity broker unavailable (#{inspect(reason)}); using per-project limits")
      fallback
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    {ceiling, maxes} = limits(opts)
    state = %{ceiling: ceiling, projects: Map.new(maxes, fn {id, max} -> {id, %{max: max, holders: MapSet.new(), ref: nil}} end)}
    publish(state)
    {:ok, state}
  end

  # `:ceiling` and `:projects` (id => max) exist so tests need no machine file.
  defp limits(opts) do
    if Keyword.has_key?(opts, :projects) do
      {opts[:ceiling], opts[:projects]}
    else
      {:ok, settings} = Settings.get()
      {override() || settings.capacity.max_agents, Map.new(settings.projects, &{String.downcase(&1.repo), &1.max_agents})}
    end
  end

  @impl true
  def handle_call({:acquire, id, issue_id, pid}, _from, %{projects: projects} = state) do
    case projects do
      %{^id => project} ->
        case admit(state, project, issue_id) do
          :ok -> {:reply, :ok, put_holders(state, id, MapSet.put(project.holders, issue_id), pid)}
          error -> {:reply, error, state}
        end

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:sync, id, issue_ids, pid}, _from, %{projects: projects} = state) do
    if Map.has_key?(projects, id),
      do: {:reply, :ok, put_holders(state, id, issue_ids, pid)},
      else: {:reply, :ok, state}
  end

  def handle_call(:snapshot, _from, state) do
    rows = Enum.map(state.projects, fn {id, p} -> %{id: id, held: MapSet.size(p.holders), max: p.max} end)
    {:reply, %{ceiling: state.ceiling, held: total(state), projects: rows}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    projects = Map.new(state.projects, fn {id, p} -> {id, if(p.ref == ref, do: %{p | holders: MapSet.new(), ref: nil}, else: p)} end)
    state = %{state | projects: projects}
    publish(state)
    {:noreply, state}
  end

  defp admit(state, %{holders: holders, max: max}, issue_id) do
    cond do
      MapSet.member?(holders, issue_id) -> :ok
      max && MapSet.size(holders) >= max -> {:error, :project_full}
      state.ceiling && total(state) >= state.ceiling -> {:error, :machine_full}
      true -> :ok
    end
  end

  defp put_holders(state, id, holders, pid) do
    project = state.projects[id]
    ref = project.ref || Process.monitor(pid)
    state = put_in(state.projects[id], %{project | holders: holders, ref: ref})
    publish(state)
    state
  end

  defp total(state), do: state.projects |> Map.values() |> Enum.map(&MapSet.size(&1.holders)) |> Enum.sum()

  defp publish(state) do
    :ets.insert(@table, {:machine, total(state), state.ceiling})
    Enum.each(state.projects, fn {id, p} -> :ets.insert(@table, {id, MapSet.size(p.holders), p.max}) end)
  end

  defp override do
    case Application.get_env(:aiur, :machine_capacity_override) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end
end
