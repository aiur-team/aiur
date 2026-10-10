defmodule Aiur.WorkflowStore.Reload do
  @moduledoc """
  The reload pipeline behind `Aiur.WorkflowStore`: stamp the config, load it,
  publish it to `Aiur.WorkflowStore.Cache` and announce changes. Takes and
  returns `%Aiur.WorkflowStore.State{}`; the GenServer stays the sole owner of
  its name and process state.
  """

  require Logger

  alias Aiur.Alerts
  alias Aiur.Workflow
  alias Aiur.WorkflowStore.Cache
  alias Aiur.WorkflowStore.State

  @reload_attempts 3
  @reload_retry_delay_ms 50
  @configuration_topic "workflow_store:configuration"
  @base_branch_changed_topic "system.config.base_branch.changed"

  @doc false
  @spec configuration_topic() :: String.t()
  def configuration_topic, do: @configuration_topic

  # Mirrors `load_state/1`'s retry rather than reading once. A caller reaching
  # this path has usually just written the config, and `File.write!/2` is not
  # atomic, so a concurrent read can land mid-write and parse-fail. The store
  # absorbs that; without the same retry here, substituting for the store would
  # turn a transient error into `{:error, {:workflow_parse_error, _}}` — and
  # `TestSupport.write_workflow_file!/2` matches `:ok =` on this result.
  @spec reload_without_store(pos_integer()) :: :ok | {:error, term()}
  def reload_without_store(attempts \\ @reload_attempts) do
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

  @spec reload_state(%State{}) :: {:ok, %State{}} | {:error, term(), %State{}}
  def reload_state(%State{} = state) do
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
  @spec load_state(Path.t(), pos_integer()) :: {:ok, %State{}} | {:error, term()}
  def load_state(path, attempts \\ @reload_attempts) do
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
    case read_config(path) do
      {:ok, content} -> stamp_for_content(path, content, known_digest, known_aux)
      {:error, reason} -> {:error, reason}
    end
  end

  # Stamps content the caller already holds, so a caller that also parses that
  # content cannot pair it with another read's digest. See `load_state/2`.
  defp stamp_for_content(path, content, known_digest, known_aux) do
    case File.stat(path, time: :posix) do
      {:ok, stat} ->
        digest = :erlang.phash2(content)
        aux = if digest == known_digest and is_map(known_aux), do: known_aux, else: resolve_aux_paths(path)

        stamp =
          {stat.mtime, stat.size, digest, file_stamp(aux.prompt), file_stamp(aux.hooks), file_stamp(aux.prewarm)}

        {:ok, stamp, digest, aux}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The single read that backs both the parsed workflow and its stamp.
  #
  # Injectable through `:workflow_store_config_reader` so a test can land a
  # write in the instant after the store reads the config — the interleaving
  # that used to leave the store permanently stale — without racing a real
  # writer against it, in the same way `:loadavg_source_override` and
  # `:proc_stat_source_override` stand in for the host probes. All three are
  # reset per case by `test/support/test_support.exs`.
  #
  # Rejecting a legacy `.aiurconfig` path is `Workflow.parse_config/2`'s job,
  # not this function's: `load_state/2` calls it on every path this store ever
  # loads, and nothing else here sees a path that has not already been through
  # it.
  defp read_config(path) do
    reader = Application.get_env(:aiur, :workflow_store_config_reader)
    read_result = if is_function(reader, 1), do: reader.(path), else: File.read(path)

    case read_result do
      {:ok, content} when is_binary(content) -> {:ok, content}
      {:error, reason} -> {:error, {:missing_workflow_file, path, reason}}
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
  @spec commit(%State{}) :: :ok
  def commit(%State{} = state), do: commit(nil, state)

  @spec commit(%State{} | nil, %State{}) :: :ok
  def commit(previous, %State{path: path} = state) do
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
