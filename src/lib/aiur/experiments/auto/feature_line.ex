defmodule Aiur.Experiments.Auto.FeatureLine do
  @moduledoc false
  use GenServer
  require Logger
  alias Aiur.Events.Exchange
  alias Aiur.Experiments.Auto.FeaturePoll
  alias Aiur.Experiments.Paths
  alias Aiur.RunTelemetry.FeatureEpics

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    opts = Keyword.put_new_lazy(opts, :path, fn -> Path.join(Paths.root(), "auto-features.json") end)
    repo = Keyword.get(opts, :managed_repo, Paths.repo())
    :ok = FeatureEpics.subscribe(repo)
    :ok = Exchange.subscribe("ticket.*.pr.merged")
    if not Keyword.get(opts, :start_paused?, false), do: send(self(), :poll)
    {:ok, %{opts: opts, task: nil, task_refresh?: false, timer: nil, refresh?: true, status: :pending, epics: %{}}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, %{status: state.status, epics: state.epics}, state}

  @impl true
  def handle_info(:poll, %{task: nil} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    task = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> FeaturePoll.run(state.opts, state.refresh?) end)
    {:noreply, %{state | task: task, task_refresh?: state.refresh?, timer: nil, refresh?: false}}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    finish(result, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state), do: finish({:error, reason}, state)

  def handle_info({:github_resource_changed, _change}, state) do
    send(self(), :poll)
    {:noreply, %{state | refresh?: true}}
  end

  def handle_info({:event, %{topic: topic}}, state) do
    known? = Enum.any?(state.epics, fn {_number, epic} -> Enum.any?(epic["member_numbers"] || [], &(topic == "ticket.#{&1}.pr.merged")) end)
    if known?, do: send(self(), :poll)
    {:noreply, %{state | refresh?: state.refresh? or known?}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{task: task}) do
    if task, do: Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp finish({:ok, data}, state) do
    timer = Process.send_after(self(), :poll, if(state.refresh?, do: 0, else: 60_000))
    epics = Map.new(data["epics"], fn {number, record} -> {number, record["state"]} end)
    {:noreply, %{state | task: nil, task_refresh?: false, timer: timer, status: :available, epics: epics}}
  end

  defp finish(error, state) do
    if state.status != :unavailable, do: Logger.warning("automatic feature line unavailable: #{inspect(error)}")
    timer = Process.send_after(self(), :poll, 60_000)
    {:noreply, %{state | task: nil, task_refresh?: false, refresh?: state.refresh? or state.task_refresh?, timer: timer, status: :unavailable}}
  end
end
