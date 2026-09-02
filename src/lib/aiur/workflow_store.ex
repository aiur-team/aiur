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

  alias Aiur.Alerts
  alias Aiur.Workflow
  alias Aiur.WorkflowStore.Cache

  @poll_interval_ms 1_000
  @call_timeout_ms 5_000
  @reload_attempts 3
  @reload_retry_delay_ms 50
  @configuration_topic "workflow_store:configuration"
  @base_branch_changed_topic "system.config.base_branch.changed"

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
      _ -> reload_without_store()
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
      reload_without_store()

    # A call to an already-dead pid can report the bare atom rather than the
    # wrapped tuple above.
    :exit, :noproc ->
      reload_without_store()
  end

  # Mirrors `load_state/1`'s retry rather than reading once. A caller reaching
  # this path has usually just written the config, and `File.write!/2` is not
  # atomic, so a concurrent read can land mid-write and parse-fail. The store
  # absorbs that; without the same retry here, substituting for the store would
  # turn a transient error into `{:error, {:workflow_parse_error, _}}` — and
  # `TestSupport.write_workflow_file!/2` matches `:ok =` on this result.
  defp reload_without_store(attempts \\ @reload_attempts) do
    case Workflow.load() do
      {:ok, _workflow} ->
        :ok

      {:error, {:workflow_parse_error, _reason}} when attempts > 1 ->
        Process.sleep(@reload_retry_delay_ms)
        reload_without_store(attempts - 1)

      {:error, reason} ->
        {:error, reason}
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
        commit(state, new_state)
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
        commit(state, new_state)
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

  # The loaded workflow and the freshness stamp that decides when to load again
  # MUST come from the same bytes. They used to come from two separate reads of
  # the config — `Workflow.load/1` and then `stamp_with_context/3` — with a
  # window between them. A write landing in that window (a `write_workflow_file!`
  # in a concurrent test, an operator editing config while the poll runs) made
  # the store record the *new* content's digest against the *old* content's
  # workflow. Every later stamp comparison then reported "unchanged", so the
  # pre-write config was served from `Cache` indefinitely — until some further
  # edit moved the digest again. That is the `core_test` "config defaults and
  # validation checks" flake: `max_concurrent_builds: -1` outliving the write
  # that replaced it with `0`, surfacing as an `ArgumentError` from a later
  # `Config.settings!/0`.
  #
  # One read, then parse and stamp that value.
  defp load_state(path, attempts \\ @reload_attempts) do
    with {:ok, content} <- read_config(path),
         {:ok, workflow} <- Workflow.parse_config(content, path),
         {:ok, stamp, digest, aux} <- stamp_for_content(path, content, nil, nil) do
      {:ok,
       %State{
         path: path,
         stamp: stamp,
         workflow: workflow,
         config_digest: digest,
         aux_paths: aux,
         base_branch: base_branch_from(workflow)
       }}
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
    with {:ok, content} <- read_config(path) do
      stamp_for_content(path, content, known_digest, known_aux)
    end
  end

  # Stamps content the caller already holds, so a caller that also parses that
  # content cannot pair it with another read's digest. See `load_state/2`.
  defp stamp_for_content(path, content, known_digest, known_aux) do
    with {:ok, stat} <- File.stat(path, time: :posix) do
      digest = :erlang.phash2(content)
      aux = if digest == known_digest and is_map(known_aux), do: known_aux, else: resolve_aux_paths(path)

      stamp =
        {stat.mtime, stat.size, digest, file_stamp(aux.prompt), file_stamp(aux.hooks), file_stamp(aux.prewarm)}

      {:ok, stamp, digest, aux}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # The single read that backs both the parsed workflow and its stamp.
  #
  # Injectable through `:workflow_store_config_reader` so a test can land a
  # write in the instant after the store reads the config — the interleaving
  # that used to leave the store permanently stale — without racing a real
  # writer against it. `:workflow_store_call_timeout_ms` exists for the
  # saturation repro for the same reason.
  defp read_config(path) do
    reader = Application.get_env(:aiur, :workflow_store_config_reader)

    if Workflow.legacy_config_path?(path) do
      {:error, Workflow.legacy_config_error(path)}
    else
      read_result = if is_function(reader, 1), do: reader.(path), else: File.read(path)

      case read_result do
        {:ok, content} when is_binary(content) -> {:ok, content}
        {:error, reason} -> {:error, {:missing_workflow_file, path, reason}}
      end
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
  defp commit(%State{} = state), do: commit(nil, state)

  defp commit(previous, %State{path: path} = state) do
    Cache.put(state.workflow, state.generation, path)
    broadcast_configuration(state)
    maybe_announce_base_branch_change(previous, state)
    :ok
  end

  defp broadcast_configuration(%State{generation: generation}) do
    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, @configuration_topic, {:workflow_config_updated, generation})
    end
  end

  # The initial commit (previous == nil) has nothing to announce. Only an
  # actual transition between two resolved base branches is a fleet-wide event:
  # it means running agents may hold a stale `AIUR_BASE_BRANCH` env value and
  # still listen on the retired branch's push topic.
  defp maybe_announce_base_branch_change(nil, _state), do: :ok

  defp maybe_announce_base_branch_change(%State{base_branch: old}, %State{base_branch: new})
       when is_binary(old) and is_binary(new) and old != new do
    announce_base_branch_change(old, new)
  end

  defp maybe_announce_base_branch_change(_previous, _state), do: :ok

  defp announce_base_branch_change(old_base, new_base) do
    message = "tracker.base_branch changed from #{old_base} to #{new_base}"

    # One Exchange event that is both semantic (structured old -> new for
    # agent-facing subscribers through the normal subscription path) and an
    # operator alert (Executor-facing feed/ledger/sound). The extra fields
    # ride the alert's exchange payload so subscribers do not receive a
    # duplicate event for the same change.
    Alerts.emit_system(@base_branch_changed_topic,
      message: message,
      reason: message,
      needs_attention: false,
      severity: "info",
      exchange_payload: %{old_base: old_base, new_base: new_base, source: :system}
    )

    :ok
  rescue
    # The alert pipeline must never take the config store down — a missing or
    # mid-restart publisher/alerts module at boot swallows the announcement
    # rather than crashing the reload that already published the new config.
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # The resolved `tracker.base_branch`, extracted defensively from the raw
  # loaded workflow config so a malformed or missing value can never crash the
  # store. Uses the same string-key shape `Config.base_branch/0` accepts.
  defp base_branch_from(%{config: %{"tracker" => %{"base_branch" => branch}}})
       when is_binary(branch) and byte_size(branch) > 0,
       do: String.trim(branch)

  defp base_branch_from(%{config: %{tracker: %{base_branch: branch}}})
       when is_binary(branch) and byte_size(branch) > 0,
       do: String.trim(branch)

  defp base_branch_from(_workflow), do: nil
end
