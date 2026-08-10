defmodule Aiur.WorkflowStore do
  @moduledoc """
  Caches the last known good workflow and reloads it when the config
  (`.aiur/config`, or a legacy `.aiurconfig`) or its referenced `prompt_file:` /
  `hooks_file:` changes.
  """

  use GenServer
  require Logger

  alias Aiur.Workflow

  @poll_interval_ms 1_000
  @call_timeout_ms 5_000
  @reload_attempts 3
  @reload_retry_delay_ms 50
  @configuration_topic "workflow_store:configuration"

  defmodule State do
    @moduledoc false

    defstruct [:path, :stamp, :workflow, :failed_stamp, generation: 1]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec current() :: {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        current_from(pid)

      _ ->
        Workflow.load()
    end
  end

  @spec current_with_generation() ::
          {:ok, Workflow.loaded_workflow(), pos_integer() | :unknown} | {:error, term()}
  def current_with_generation do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        current_with_generation_from(pid)

      _ ->
        with {:ok, workflow} <- Workflow.load(), do: {:ok, workflow, :unknown}
    end
  end

  # The store is a cache over one small config file, so ANY failure to reach it
  # — including a `:timeout` on a saturated host — degrades correctly to reading
  # that same file from disk. Leaving `:timeout` uncaught used to kill the
  # calling process instead: on the `aiur status` read path that killed the RPC
  # evaluator itself, which the operator saw as a non-zero exit with an empty
  # buffer (#1684). Match on this exact call so unrelated exits still propagate.
  defp current_from(pid) do
    GenServer.call(pid, :current, call_timeout())
  catch
    :exit, {_reason, {GenServer, :call, [^pid, :current, _timeout]}} ->
      Workflow.load()
  end

  defp current_with_generation_from(pid) do
    GenServer.call(pid, :current_with_generation, call_timeout())
  catch
    :exit, {_reason, {GenServer, :call, [^pid, :current_with_generation, _timeout]}} ->
      with {:ok, workflow} <- Workflow.load(), do: {:ok, workflow, :unknown}
  end

  # Overridable so the saturation repro can stall the store without a real
  # five-second wait.
  defp call_timeout, do: Application.get_env(:aiur, :workflow_store_call_timeout_ms, @call_timeout_ms)

  @spec force_reload() :: :ok | {:error, term()}
  def force_reload do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :force_reload)

      _ ->
        case Workflow.load() do
          {:ok, _workflow} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec subscribe(pid()) :: :ok | {:error, term()}
  def subscribe(_pid \\ self()), do: Phoenix.PubSub.subscribe(Aiur.PubSub, @configuration_topic)

  @impl true
  def init(_opts) do
    case load_state(Workflow.workflow_file_path()) do
      {:ok, state} ->
        broadcast_configuration(state)
        schedule_poll()
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:current, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}
    end
  end

  def handle_call(:current_with_generation, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.workflow, new_state.generation}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.workflow, new_state.generation}, new_state}
    end
  end

  def handle_call(:force_reload, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    schedule_poll()

    case reload_state(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp reload_state(%State{} = state) do
    path = Workflow.workflow_file_path()

    if path != state.path do
      reload_path(path, state)
    else
      reload_current_path(path, state)
    end
  end

  defp reload_path(path, state) do
    case load_state(path) do
      {:ok, new_state} ->
        new_state = advance_generation(new_state, state)
        broadcast_configuration(new_state)
        {:ok, new_state}

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp reload_current_path(path, state) do
    case current_stamp(path) do
      {:ok, stamp} when stamp == state.stamp ->
        {:ok, state}

      {:ok, stamp} ->
        reload_changed_stamp(path, stamp, state)

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp reload_changed_stamp(path, stamp, state) do
    case load_state(path) do
      {:ok, new_state} ->
        new_state = advance_generation(new_state, state)
        broadcast_configuration(new_state)
        {:ok, new_state}

      {:error, reason} ->
        # Keep the prior stamp so the next poll retries: a transient load
        # error must not mark the new content as current, or a later good
        # reload gets skipped and stale config is served. Track the failing
        # stamp separately so a persistently-broken config still logs once
        # per change instead of every poll.
        if stamp != state.failed_stamp, do: log_reload_error(path, reason)
        {:error, reason, %{state | failed_stamp: stamp}}
    end
  end

  defp load_state(path, attempts \\ @reload_attempts) do
    with {:ok, workflow} <- Workflow.load(path),
         {:ok, stamp} <- current_stamp(path) do
      {:ok, %State{path: path, stamp: stamp, workflow: workflow}}
    else
      {:error, {:workflow_parse_error, _reason}} when attempts > 1 ->
        Process.sleep(@reload_retry_delay_ms)
        load_state(path, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_stamp(path) when is_binary(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, content} <- File.read(path) do
      {:ok, {stat.mtime, stat.size, :erlang.phash2(content), prompt_file_stamp(path), hooks_file_stamp(path), prewarm_file_stamp(path)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp prompt_file_stamp(path) do
    case Workflow.resolved_prompt_file_path(path) do
      prompt_path when is_binary(prompt_path) ->
        case File.read(prompt_path) do
          {:ok, body} -> :erlang.phash2(body)
          {:error, _reason} -> nil
        end

      nil ->
        nil
    end
  end

  defp hooks_file_stamp(path) do
    case Workflow.resolved_hooks_file_path(path) do
      hooks_path when is_binary(hooks_path) ->
        case File.read(hooks_path) do
          {:ok, body} -> :erlang.phash2(body)
          {:error, _reason} -> nil
        end

      nil ->
        nil
    end
  end

  defp prewarm_file_stamp(path) do
    case Workflow.resolved_prewarm_file_path(path) do
      prewarm_path when is_binary(prewarm_path) ->
        case File.read(prewarm_path) do
          {:ok, body} -> :erlang.phash2(body)
          {:error, _reason} -> nil
        end

      nil ->
        nil
    end
  end

  defp log_reload_error(path, reason) do
    Logger.error("Failed to reload workflow path=#{path} reason=#{inspect(reason)}; keeping last known good configuration")
  end

  defp advance_generation(new_state, state) do
    %{new_state | generation: state.generation + 1}
  end

  defp broadcast_configuration(%State{generation: generation}) do
    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, @configuration_topic, {:workflow_config_updated, generation})
    end
  end
end
