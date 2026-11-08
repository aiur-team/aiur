defmodule Aiur.Ownership.Fence do
  @moduledoc """
  Answers "does this agent still own its ticket?" for the `git`/`gh` guards (MPG-105).

  The daemon registers the claim (`Aiur.Ownership.ensure_owned/2` record) before an agent
  starts, keyed by the ticket's identifier, which is also the workspace directory name. A
  check compares the registered gateway, daemon and epoch with the owner ref. The ref read
  is reused for 30 s and refreshed after that; a failed read is never cached and answers
  `{:unknown, _}`, so the guard fails closed. Checks run inside this process, which makes
  concurrent checks for one ticket share a single read.
  """
  use GenServer

  alias Aiur.Ownership
  alias Aiur.Ownership.GitHubRef

  @max_age_ms 30_000

  @type verdict :: {:ok, map()} | {:moved, map()} | {:unknown, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The fence, only while `instance.ownership: github`. Its socket is started by `Aiur.Application.Children`."
  @spec child_specs() :: [module()]
  def child_specs, do: if(Ownership.enabled?(), do: [__MODULE__], else: [])

  @doc "Records the claim an agent starts under. `issue` supplies the identifier and repository."
  @spec register(Aiur.Issue.t(), Ownership.Record.t(), GenServer.server()) :: :ok
  def register(issue, record, server \\ __MODULE__) do
    GenServer.call(server, {:register, to_string(issue.identifier), record})
  catch
    :exit, _ -> :ok
  end

  @spec unregister(String.t(), GenServer.server()) :: :ok
  def unregister(identifier, server \\ __MODULE__), do: GenServer.cast(server, {:unregister, to_string(identifier)})

  @doc "Checks the agent whose workspace directory is named `identifier`."
  @spec check(String.t(), keyword()) :: verdict()
  def check(identifier, opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:check, identifier, opts}, 60_000)
  catch
    :exit, _ -> {:unknown, :fence_unavailable}
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       registered: %{},
       reads: %{},
       notified: MapSet.new(),
       read_fun: Keyword.get(opts, :read_fun, &GitHubRef.read/3),
       notify: Keyword.get(opts, :notify, &notify_orchestrator/2)
     }}
  end

  defp notify_orchestrator(id, epoch) do
    case GenServer.whereis(Aiur.Project.whereis(Aiur.Orchestrator)) do
      nil -> :ok
      pid -> send(pid, {:ownership_moved, id, epoch})
    end
  end

  @impl true
  def handle_call({:register, id, record}, _from, state) do
    {:reply, :ok, %{state | registered: Map.put(state.registered, id, record), reads: Map.delete(state.reads, id)}}
  end

  def handle_call({:check, id, opts}, _from, state) do
    case Map.fetch(state.registered, id) do
      :error ->
        {:reply, {:unknown, :no_registration}, state}

      {:ok, record} ->
        now = Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
        {observed, state} = observe(state, id, record, now)
        verdict = verdict(observed, record)
        {:reply, verdict, notify_moved(state, id, record, verdict)}
    end
  end

  # Once per {ticket, epoch}, so the orchestrator stops the run and alerts once.
  defp notify_moved(state, id, record, {:moved, _}) do
    key = {id, record.epoch}

    if MapSet.member?(state.notified, key) do
      state
    else
      state.notify.(id, record.epoch)
      %{state | notified: MapSet.put(state.notified, key)}
    end
  end

  defp notify_moved(state, _id, _record, _verdict), do: state

  @impl true
  def handle_cast({:unregister, id}, state) do
    {:noreply, %{state | registered: Map.delete(state.registered, id), reads: Map.delete(state.reads, id)}}
  end

  defp observe(state, id, record, now) do
    case state.reads do
      %{^id => {at, observed}} when now - at <= @max_age_ms ->
        {observed, state}

      _ ->
        case state.read_fun.(record.repo, record.ticket, []) do
          {:ok, %{record: current}} -> {{:ok, current}, %{state | reads: Map.put(state.reads, id, {now, {:ok, current}})}}
          {:ok, _no_record} -> {{:ok, nil}, %{state | reads: Map.put(state.reads, id, {now, {:ok, nil}})}}
          {:unknown, why} -> {{:error, why}, state}
        end
    end
  end

  defp verdict({:error, why}, _mine), do: {:unknown, {:read_failed, why}}
  defp verdict({:ok, nil}, mine), do: {:moved, %{owner: "-", epoch: mine.epoch, state: "absent"}}

  defp verdict({:ok, current}, mine) do
    if current.state == "owned" and current.gateway_id == mine.gateway_id and current.daemon_key == mine.daemon_key and
         current.epoch == mine.epoch do
      {:ok, %{epoch: mine.epoch}}
    else
      {:moved, %{owner: if(current.state == "owned", do: current.gateway_label, else: "-"), epoch: current.epoch, state: current.state}}
    end
  end
end
