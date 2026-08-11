defmodule Aiur.WorkflowStore do
  @moduledoc """
  Caches the last known good workflow and reloads it when the config
  (`.aiur/config`, or a legacy `.aiurconfig`) or its referenced `prompt_file:` /
  `hooks_file:` changes.

  ## Reads do not enter this mailbox (#1731)

  Every `Aiur.Config.settings/0` used to be a `GenServer.call` into this
  process, and each such call re-stamped the config from disk — four file reads
  and three YAML parses per read. That made the store a system-wide mutex on a
  hot path: the orchestrator was caught blocked in `gen:do_call/4` waiting here
  with 10,456 messages queued behind it, which is what made `aiur status` and
  `aiur agents` time out.

  The store now owns freshness alone. It polls once a second, and on every
  change publishes the loaded workflow into `Aiur.WorkflowStore.Cache` (ETS).
  Readers take the value straight from ETS, so a read costs one lookup, never
  waits on another reader, and cannot be delayed by this process's own reload
  work. Worst-case staleness is one poll interval; callers that must observe a
  write immediately (the test helpers, `Workflow.set_workflow_file_path/1`)
  still go through the synchronous `force_reload/0`.
  """

  use GenServer
  require Logger

  alias Aiur.Workflow
  alias Aiur.WorkflowStore.Cache

  @poll_interval_ms 1_000
  @call_timeout_ms 5_000
  @reload_attempts 3
  @reload_retry_delay_ms 50
  @configuration_topic "workflow_store:configuration"

  defmodule State do
    @moduledoc false

    defstruct [:path, :stamp, :workflow, :failed_stamp, :config_digest, :aux_paths, generation: 1]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec current() :: {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def current do
    case Cache.fetch() do
      {:ok, workflow, _generation} ->
        {:ok, workflow}

      :error ->
        case Process.whereis(__MODULE__) do
          pid when is_pid(pid) -> current_from(pid)
          _ -> Workflow.load()
        end
    end
  end

  @spec current_with_generation() ::
          {:ok, Workflow.loaded_workflow(), pos_integer() | :unknown} | {:error, term()}
  def current_with_generation do
    case Cache.fetch() do
      {:ok, workflow, generation} ->
        {:ok, workflow, generation}

      :error ->
        case Process.whereis(__MODULE__) do
          pid when is_pid(pid) -> current_with_generation_from(pid)
          _ -> load_with_unknown_generation()
        end
    end
  end

  defp load_with_unknown_generation do
    with {:ok, workflow} <- Workflow.load(), do: {:ok, workflow, :unknown}
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
  @spec force_reload(timeout()) :: :ok | {:error, term()}
  def force_reload(timeout \\ @call_timeout_ms) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :force_reload, timeout)

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
    Cache.init!()

    case load_state(Workflow.workflow_file_path()) do
      {:ok, state} ->
        commit(state)
        schedule_poll()
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # Reads normally never reach here — they are served from `Cache`. These
  # clauses only cover the narrow window between this process being registered
  # and `init/1` publishing, and they deliberately do NOT reload: reloading on
  # a read is what turned this mailbox into a system-wide queue (#1731).
  @impl true
  def handle_call(:current, _from, %State{} = state) do
    {:reply, {:ok, state.workflow}, state}
  end

  def handle_call(:current_with_generation, _from, %State{} = state) do
    {:reply, {:ok, state.workflow, state.generation}, state}
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
        commit(new_state)
        {:ok, new_state}

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp reload_current_path(path, state) do
    case current_stamp(path, state) do
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
        commit(new_state)
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
         {:ok, stamp, digest, aux} <- stamp_with_context(path, nil, nil) do
      {:ok, %State{path: path, stamp: stamp, workflow: workflow, config_digest: digest, aux_paths: aux}}
    else
      {:error, {:workflow_parse_error, _reason}} when attempts > 1 ->
        Process.sleep(@reload_retry_delay_ms)
        load_state(path, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_stamp(path, %State{config_digest: digest, aux_paths: aux}) when is_binary(path) do
    with {:ok, stamp, _digest, _aux} <- stamp_with_context(path, digest, aux) do
      {:ok, stamp}
    end
  end

  # Stamping used to cost four reads of the config and three YAML parses of it:
  # `Workflow.resolved_prompt_file_path/1`, `resolved_hooks_file_path/1` and
  # `resolved_prewarm_file_path/1` each re-read and re-decoded the file just to
  # pull one key out. That YAML decode is the regex work `:re.urun` was caught
  # running inside this process in #1731.
  #
  # The referenced paths can only change when the config content changes, and
  # the content hash already tells us that. So parse once per content change and
  # carry the resolved paths in state; the steady-state poll now does one config
  # read plus one read per referenced file, and no parsing at all.
  defp stamp_with_context(path, known_digest, known_aux) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, content} <- File.read(path) do
      digest = :erlang.phash2(content)
      aux = if digest == known_digest and is_map(known_aux), do: known_aux, else: resolve_aux_paths(path)

      stamp =
        {stat.mtime, stat.size, digest, file_stamp(aux.prompt), file_stamp(aux.hooks), file_stamp(aux.prewarm)}

      {:ok, stamp, digest, aux}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_aux_paths(path) do
    %{
      prompt: Workflow.resolved_prompt_file_path(path),
      hooks: Workflow.resolved_hooks_file_path(path),
      prewarm: Workflow.resolved_prewarm_file_path(path)
    }
  end

  defp file_stamp(file_path) when is_binary(file_path) do
    case File.read(file_path) do
      {:ok, body} -> :erlang.phash2(body)
      {:error, _reason} -> nil
    end
  end

  defp file_stamp(nil), do: nil

  defp log_reload_error(path, reason) do
    Logger.error("Failed to reload workflow path=#{path} reason=#{inspect(reason)}; keeping last known good configuration")
  end

  defp advance_generation(new_state, state) do
    %{new_state | generation: state.generation + 1}
  end

  # Publish before announcing. A subscriber woken by the broadcast reads through
  # `Cache`, so the new value has to be visible there first or the listener
  # would race back to the value it was told had changed.
  defp commit(%State{} = state) do
    Cache.put(state.workflow, state.generation)
    broadcast_configuration(state)
    :ok
  end

  defp broadcast_configuration(%State{generation: generation}) do
    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, @configuration_topic, {:workflow_config_updated, generation})
    end
  end
end
