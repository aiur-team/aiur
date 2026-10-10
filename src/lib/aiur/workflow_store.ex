defmodule Aiur.WorkflowStore do
  @moduledoc """
  Caches the last known good workflow and reloads it when the config
  (`.aiur/config`) or its referenced `prompt_file:` /
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
  alias Aiur.WorkflowStore.Reload

  @poll_interval_ms 1_000
  @call_timeout_ms 5_000

  defmodule State do
    @moduledoc false

    defstruct [
      :path,
      :stamp,
      :workflow,
      :failed_stamp,
      :config_digest,
      :aux_paths,
      :base_branch,
      generation: 1
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec current() :: {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def current do
    case Cache.fetch(Workflow.workflow_file_path()) do
      {:ok, workflow, _generation, _publication} ->
        {:ok, workflow}

      # The cache holds a config loaded from a different path — a reload that
      # re-pointed this singleton at another config landed after the caller's
      # own fixture was loaded and awaited (#2133). Serving it would hand a
      # caller a config that is not its own, so refuse the entry and read the
      # caller's current path from disk instead. The store catches up on its
      # next reload.
      {:stale, _cached_path} ->
        Workflow.load()

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
    case Cache.fetch(Workflow.workflow_file_path()) do
      {:ok, workflow, generation, _publication} ->
        {:ok, workflow, generation}

      {:stale, _cached_path} ->
        load_with_unknown_generation()

      :error ->
        case Process.whereis(__MODULE__) do
          pid when is_pid(pid) -> current_with_generation_from(pid)
          _ -> load_with_unknown_generation()
        end
    end
  end

  @doc false
  @spec current_with_cache_identity() ::
          {:ok, Workflow.loaded_workflow(), pos_integer() | :unknown, reference() | :unknown} | {:error, term()}
  def current_with_cache_identity do
    case Cache.fetch(Workflow.workflow_file_path()) do
      {:ok, workflow, generation, publication} ->
        {:ok, workflow, generation, publication}

      {:stale, _cached_path} ->
        load_with_unknown_cache_identity()

      :error ->
        case Process.whereis(__MODULE__) do
          pid when is_pid(pid) ->
            current_with_cache_identity_from(pid)

          _ ->
            load_with_unknown_cache_identity()
        end
    end
  end

  defp load_with_unknown_generation do
    with {:ok, workflow} <- Workflow.load(), do: {:ok, workflow, :unknown}
  end

  defp load_with_unknown_cache_identity do
    with {:ok, workflow} <- Workflow.load(), do: {:ok, workflow, :unknown, :unknown}
  end

  defp current_with_cache_identity_from(pid) do
    with {:ok, workflow} <- current_from(pid), do: {:ok, workflow, :unknown, :unknown}
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
      pid when is_pid(pid) -> call_force_reload(timeout)
      _ -> Reload.reload_without_store()
    end
  end

  # The store can terminate between the `whereis/1` above and this call: it is a
  # supervised singleton, so any restart — or a test tearing it down — leaves
  # that window open. An exiting `GenServer.call` would then propagate out of an
  # unrelated caller, which both contradicts this function's `:ok | {:error, _}`
  # contract and is how a sibling's restart surfaced as an EXIT inside a
  # different test (`WorkspaceAndConfigTest`, CI run 31897085819).
  #
  # A dead store is the same situation as an absent one, so it takes the same
  # fallback: the restarting incarnation reloads the current path in `init/1`,
  # so confirming the file loads is the equivalent guarantee.
  #
  # Only two exit classes are re-raised, because both mean the caller can still
  # be looking at a stale cache and must find out. Everything else is absorbed.
  #
  # Listing the death reasons instead would be unfixably incomplete: an exit
  # reason is an arbitrary term, and `init/1` below stops with
  # `{:missing_workflow_file, path}` or `{:workflow_parse_error, _}` when the
  # config path is transiently bad — which `test/support/test_support.exs`
  # documents as something that actually happens in this suite. `start_link/1`
  # registers the name *before* `init/1` runs, so `whereis/1` can hand back a
  # pid whose init then stops with exactly those tuples. A whitelist would let
  # them through, which is the very race this function is closing.
  #
  # The call is pinned the same way `current_from/1` pins its own, so an exit
  # raised by anything other than this call still propagates.
  defp call_force_reload(timeout) do
    GenServer.call(__MODULE__, :force_reload, timeout)
  catch
    # Alive but not answering. `:workflow_store_call_timeout_ms` exists so the
    # saturation repro can exercise this path.
    :exit, {:timeout, {GenServer, :call, [__MODULE__, :force_reload, _timeout]}} = reason ->
      exit(reason)

    # A real bug took the store down, e.g. config content that crashes the
    # reload. Absorbing that would turn a loud failure into a silent one.
    :exit, {{exception, stacktrace}, {GenServer, :call, [__MODULE__, :force_reload, _timeout]}} = reason
    when is_exception(exception) and is_list(stacktrace) ->
      exit(reason)

    # Any other death — including a `{:stop, reason}` from a restarting
    # `init/1` — is the same situation as an absent store.
    :exit, {_reason, {GenServer, :call, [__MODULE__, :force_reload, _timeout]}} ->
      Reload.reload_without_store()

    # A call to an already-dead pid can report the bare atom rather than the
    # wrapped tuple above.
    :exit, :noproc ->
      Reload.reload_without_store()
  end

  @spec subscribe(pid()) :: :ok | {:error, term()}
  def subscribe(_pid \\ self()), do: Phoenix.PubSub.subscribe(Aiur.PubSub, Reload.configuration_topic())

  @impl true
  def init(_opts) do
    Cache.init!()

    case Reload.load_state(Workflow.workflow_file_path()) do
      {:ok, state} ->
        Reload.commit(state)
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
    case Reload.reload_state(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    schedule_poll()

    case Reload.reload_state(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end
end
