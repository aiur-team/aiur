defmodule Aiur.Orchestrator.GlobalPause do
  @moduledoc """
  The single global pause switch: a daemon-wide halt distinct from per-agent pause.

  Pausing stops provisioning (`Slots.available_slots/1` returns 0 while paused,
  so no agents spin up even with `agent:todo` tickets) while existing agents
  continue to be observed by the normal poll cycle.

  The switch also cold-starts from the `--pause` launch flag via
  `Aiur.Orchestrator.Slots.launch_globally_paused?/0`, seeded on orchestrator init.
  All state mutation runs inside the orchestrator GenServer process.
  """

  alias Aiur.Issue
  alias Aiur.ModelAvailability
  alias Aiur.Orchestrator.{DispatchPolicy, GlobalPauseStore, Lifecycle, SnapshotStore, State, StatusReport}
  alias Aiur.Orchestrator.PauseResume.Resume

  @call_timeout 15_000

  @doc "Whether the daemon is currently globally paused, or whether that truth is unavailable."
  @spec globally_paused?() :: {:ok, boolean()} | {:error, :orchestrator_unavailable}
  def globally_paused?, do: globally_paused?(Aiur.Orchestrator)

  @spec globally_paused?(GenServer.server()) :: {:ok, boolean()} | {:error, :orchestrator_unavailable}
  def globally_paused?(server) do
    if GenServer.whereis(server) do
      {:ok, GenServer.call(server, :globally_paused?, 5_000)}
    else
      {:error, :orchestrator_unavailable}
    end
  catch
    :exit, _ -> {:error, :orchestrator_unavailable}
  end

  @doc "Returns the global pause state and its recorded provenance."
  @spec global_pause_status() :: {:ok, map()} | {:error, :timeout | :orchestrator_unavailable}
  def global_pause_status, do: global_pause_status(Aiur.Orchestrator)

  @spec global_pause_status(GenServer.server()) ::
          {:ok, map()} | {:error, :timeout | :orchestrator_unavailable}
  def global_pause_status(%State{} = state), do: global_pause_status_for_state(state)
  def global_pause_status(server), do: global_pause_status(server, 5_000)

  @spec global_pause_status(GenServer.server(), pos_integer()) ::
          {:ok, map()} | {:error, :timeout | :orchestrator_unavailable}
  def global_pause_status(server, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    if GenServer.whereis(server) do
      {:ok, GenServer.call(server, :global_pause_status, timeout_ms)}
    else
      {:error, :orchestrator_unavailable}
    end
  catch
    :exit, {:timeout, _details} -> {:error, :timeout}
    :exit, _ -> {:error, :orchestrator_unavailable}
  end

  @doc """
  Flip the global pause switch. `true` stops provisioning while existing agents
  continue to run and be observed; `false` re-enables provisioning. Idempotent.
  """
  @spec set_global_pause(boolean()) :: {:ok, map()} | {:error, term()}
  def set_global_pause(on?) when is_boolean(on?),
    do: set_global_pause(Aiur.Orchestrator, on?, "CLI")

  @spec set_global_pause(GenServer.server(), boolean()) :: {:ok, map()} | {:error, term()}
  def set_global_pause(server, on?) when is_boolean(on?), do: set_global_pause(server, on?, "CLI")

  @spec set_global_pause(GenServer.server(), boolean(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def set_global_pause(server, on?, source) when is_boolean(on?) and is_binary(source),
    do: set_global_pause(server, on?, source, @call_timeout)

  @doc false
  @spec set_global_pause(GenServer.server(), boolean(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def set_global_pause(server, on?, source, timeout_ms)
      when is_boolean(on?) and is_binary(source) and is_integer(timeout_ms) and timeout_ms > 0 do
    if GenServer.whereis(server) do
      GenServer.call(server, {:set_global_pause, on?, source}, timeout_ms)
    else
      {:error, :orchestrator_unavailable}
    end
  catch
    :exit, {:timeout, _details} -> {:error, :timeout}
    :exit, reason -> {:error, {:orchestrator_call_failed, reason}}
  end

  @doc false
  @spec globally_paused_call(State.t()) :: {:reply, boolean(), State.t()}
  def globally_paused_call(%State{globally_paused: paused} = state), do: {:reply, paused, state}

  @doc false
  @spec set_global_pause_call(State.t(), boolean()) ::
          {:reply, {:ok, map()} | {:error, term()}, State.t()}
  def set_global_pause_call(state, on?) when is_boolean(on?),
    do: set_global_pause_call(state, on?, "CLI", [])

  @spec set_global_pause_call(State.t(), boolean(), String.t()) ::
          {:reply, {:ok, map()} | {:error, term()}, State.t()}
  def set_global_pause_call(%State{} = state, on?, source)
      when is_boolean(on?) do
    set_global_pause_call(state, on?, source, [])
  end

  @doc false
  @spec set_global_pause_call(State.t(), boolean(), String.t(), keyword()) ::
          {:reply, {:ok, map()} | {:error, term()}, State.t()}
  def set_global_pause_call(%State{globally_paused: current} = state, on?, source, opts)
      when is_boolean(on?) and is_list(opts) do
    source = normalize_source(source)
    next_state = next_global_pause_state(state, current, on?, source)

    case GlobalPauseStore.save(global_pause_status_for_state(next_state)) do
      :ok ->
        state =
          next_state
          |> maybe_refresh_after_global_pause_change(current, on?, opts)

        publish_global_pause(state)
        StatusReport.notify_dashboard(state)
        {:reply, {:ok, global_pause_status_for_state(state)}, state}

      {:error, reason} ->
        {:reply, {:error, {:global_pause_persistence_failed, reason}}, state}
    end
  end

  defp next_global_pause_state(state, false, true, source) do
    state
    |> Map.put(:globally_paused, true)
    |> Map.put(:global_pause, %{paused_at: DateTime.utc_now(), source: source})
  end

  defp next_global_pause_state(state, true, false, _source) do
    state
    |> Map.put(:globally_paused, false)
    |> Map.put(:global_pause, %{paused_at: nil, source: nil})
  end

  defp next_global_pause_state(state, _current, _on?, _source), do: state

  # An idle fleet may have a substantially widened timer. Unpausing is an
  # explicit admission request, so cancel that timer and reconcile fresh state
  # before any queued ticket can dispatch.
  defp maybe_refresh_after_global_pause_change(state, false, true, _opts),
    do: state |> Lifecycle.request_refresh_state() |> elem(0)

  defp maybe_refresh_after_global_pause_change(state, true, false, opts) do
    backends = Keyword.get(opts, :backends, DispatchPolicy.read_provider_backends())
    ModelAvailability.probe_stale_limits(backends, opts)

    state
    |> resume_legacy_global_pause_entries()
    |> Lifecycle.request_refresh_state()
    |> elem(0)
  end

  defp maybe_refresh_after_global_pause_change(state, _current, _on?, _opts), do: state

  # Older releases parked running workers when global pause was enabled. Release
  # only those legacy holds during unpause; new pauses leave workers untouched.
  defp resume_legacy_global_pause_entries(%State{} = state) do
    Enum.reduce(state.running, state, fn
      {issue_id, %{paused_reason: :global_pause, issue: issue} = entry}, acc ->
        resume_legacy_global_pause_entry(acc, issue_id, entry, issue)

      _, acc ->
        acc
    end)
  end

  defp resume_legacy_global_pause_entry(state, issue_id, entry, issue) do
    if Issue.paused?(issue), do: state, else: resume_legacy_global_pause_entry(state, issue_id, entry)
  end

  defp resume_legacy_global_pause_entry(state, issue_id, entry) do
    {_reply, next} = Resume.resume_running_issue(state, entry)
    if Map.has_key?(next.running, issue_id), do: next, else: state
  end

  defp publish_global_pause(%State{} = state) do
    SnapshotStore.publish_global_pause(
      state.snapshot_key || self(),
      state.snapshot_generation,
      global_pause_status_for_state(state)
    )
  end

  @doc false
  @spec global_pause_status_for_state(State.t()) :: map()
  defp global_pause_status_for_state(%State{globally_paused: paused, global_pause: metadata}) do
    %{
      globally_paused: paused,
      paused_at: Map.get(metadata, :paused_at),
      source: Map.get(metadata, :source)
    }
  end

  defp global_pause_status_for_state(%State{globally_paused: paused}),
    do: %{globally_paused: paused, paused_at: nil, source: nil}

  defp normalize_source(source) when is_binary(source) and source != "", do: source
  defp normalize_source(source) when is_atom(source), do: Atom.to_string(source)
  defp normalize_source(_), do: "unknown"
end
