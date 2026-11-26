defmodule Aiur.Project.Watcher do
  @moduledoc """
  Watches every project root. A root that fails to start or exits abnormally
  raises `system.project.boot_failed` and is remembered as failed; the other
  projects keep running. A later successful start raises `.resolved`.
  Nothing restarts a failed project: `aiur gateway reload` retries it.
  """
  use GenServer

  @alert "system.project.boot_failed"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec started(Aiur.Project.t(), pid()) :: :ok
  def started(project, pid), do: GenServer.call(__MODULE__, {:started, project, pid})

  @spec failed(Aiur.Project.t(), term()) :: :ok
  def failed(project, reason), do: GenServer.call(__MODULE__, {:failed, project, reason})

  @doc "Called before a deliberate stop: the tree's exit is not a failure, and a failed project is forgotten."
  @spec stopping(Aiur.Project.id()) :: :ok
  def stopping(project_id), do: GenServer.call(__MODULE__, {:stopping, project_id})

  @doc "Projects whose last start failed or whose tree stopped abnormally: `%{id => project}`."
  @spec failures() :: %{Aiur.Project.id() => Aiur.Project.t()}
  def failures, do: GenServer.call(__MODULE__, :failures)

  @impl true
  def init(opts), do: {:ok, %{refs: %{}, failed: %{}, alert_fun: Keyword.fetch!(opts, :alert_fun)}}

  @impl true
  def handle_call({:started, project, pid}, _from, state) do
    ref = Process.monitor(pid)
    if Map.has_key?(state.failed, project.id), do: alert(state, @alert <> ".resolved", "#{project.repo} started", false)
    {:reply, :ok, %{state | refs: Map.put(state.refs, ref, project), failed: Map.delete(state.failed, project.id)}}
  end

  def handle_call({:failed, project, reason}, _from, state), do: {:reply, :ok, record_failure(state, project, reason)}

  def handle_call({:stopping, id}, _from, state) do
    {stopped, refs} = Map.split_with(state.refs, fn {_ref, project} -> project.id == id end)
    Enum.each(Map.keys(stopped), &Process.demonitor(&1, [:flush]))
    {:reply, :ok, %{state | refs: refs, failed: Map.delete(state.failed, id)}}
  end

  def handle_call(:failures, _from, state), do: {:reply, state.failed, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {project, refs} = Map.pop(state.refs, ref)
    state = %{state | refs: refs}

    # Any exit of a watched root is a failure: a deliberate stop unwatches it first, and a
    # supervisor that exhausts its restart intensity exits `:shutdown` too.
    if project, do: {:noreply, record_failure(state, project, reason)}, else: {:noreply, state}
  end

  defp record_failure(state, project, reason) do
    alert(state, @alert, "#{project.repo} stopped: #{describe(project, reason)}; other projects keep running", true)
    %{state | failed: Map.put(state.failed, project.id, project)}
  end

  # The config path is machine-local; it never reaches an alert.
  defp describe(project, reason) do
    reason
    |> inspect(limit: 20, printable_limit: 200)
    |> String.replace(project.config_path, "<config>")
    |> String.replace(Path.dirname(project.config_path), "<config dir>")
    |> String.slice(0, 200)
  end

  defp alert(state, name, message, needs_attention) do
    state.alert_fun.(name, message: message, needs_attention: needs_attention, severity: if(needs_attention, do: "warning", else: "info"))
  end
end
