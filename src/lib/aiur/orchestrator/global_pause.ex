defmodule Aiur.Orchestrator.GlobalPause do
  @moduledoc """
  The single global pause switch: a daemon-wide halt distinct from per-agent pause.

  Pausing holds every running agent that is not already individually paused and
  stops all provisioning (`Slots.available_slots/1` returns 0 while paused, so no
  agents spin up even with `agent:todo` tickets). Unpausing resumes only the
  agents this switch held, never overriding an operator's per-agent pause.

  The switch also cold-starts from the `--pause` launch flag via
  `Aiur.Orchestrator.Slots.launch_globally_paused?/0`, seeded on orchestrator init.
  All state mutation runs inside the orchestrator GenServer process.
  """

  alias Aiur.Orchestrator.{GlobalPauseStore, PauseResume, State, StatusReport}

  @call_timeout 15_000

  @doc "Whether the daemon is currently globally paused. False when the orchestrator is unavailable."
  @spec globally_paused?() :: boolean()
  def globally_paused?, do: globally_paused?(Aiur.Orchestrator)

  @spec globally_paused?(GenServer.server()) :: boolean()
  def globally_paused?(server) do
    if GenServer.whereis(server) do
      GenServer.call(server, :globally_paused?, 5_000)
    else
      false
    end
  catch
    :exit, _ -> false
  end

  @doc "Returns the global pause state and its recorded provenance."
  @spec global_pause_status() :: map()
  def global_pause_status, do: global_pause_status(Aiur.Orchestrator)

  @spec global_pause_status(GenServer.server()) :: map()
  def global_pause_status(%State{} = state), do: global_pause_status_for_state(state)

  def global_pause_status(server) do
    if GenServer.whereis(server) do
      GenServer.call(server, :global_pause_status, 5_000)
    else
      %{globally_paused: false, paused_at: nil, source: nil}
    end
  catch
    :exit, _ -> %{globally_paused: false, paused_at: nil, source: nil}
  end

  @doc """
  Flip the global pause switch. `true` pauses the daemon and holds all running
  agents; `false` unpauses and resumes only the globally held agents. Idempotent.
  """
  @spec set_global_pause(boolean()) :: {:ok, map()} | {:error, term()}
  def set_global_pause(on?) when is_boolean(on?), do: set_global_pause(Aiur.Orchestrator, on?, "CLI")

  @spec set_global_pause(GenServer.server(), boolean()) :: {:ok, map()} | {:error, term()}
  def set_global_pause(server, on?) when is_boolean(on?), do: set_global_pause(server, on?, "CLI")

  @spec set_global_pause(GenServer.server(), boolean(), String.t()) :: {:ok, map()} | {:error, term()}
  def set_global_pause(server, on?, source) when is_boolean(on?) and is_binary(source) do
    if GenServer.whereis(server) do
      GenServer.call(server, {:set_global_pause, on?, source}, @call_timeout)
    else
      {:error, :orchestrator_unavailable}
    end
  catch
    :exit, reason -> {:error, {:orchestrator_call_failed, reason}}
  end

  @doc false
  @spec globally_paused_call(State.t()) :: {:reply, boolean(), State.t()}
  def globally_paused_call(%State{globally_paused: paused} = state), do: {:reply, paused, state}

  @doc false
  @spec set_global_pause_call(State.t(), boolean()) :: {:reply, {:ok, map()}, State.t()}
  def set_global_pause_call(%State{globally_paused: current} = state, on?, source \\ "CLI") when is_boolean(on?) do
    source = normalize_source(source)

    state =
      cond do
        on? and not current ->
          state
          |> Map.put(:globally_paused, true)
          |> Map.put(:global_pause, %{paused_at: DateTime.utc_now(), source: source})
          |> then(&PauseResume.pause_running_for_global/1)

        not on? and current ->
          state
          |> Map.put(:globally_paused, false)
          |> Map.put(:global_pause, %{paused_at: nil, source: nil})
          |> then(&PauseResume.resume_running_from_global/1)

        true ->
          state
      end

    :ok = GlobalPauseStore.save(global_pause_status_for_state(state))
    StatusReport.notify_dashboard(state)
    {:reply, {:ok, global_pause_status_for_state(state)}, state}
  end

  @doc false
  @spec global_pause_status_for_state(State.t()) :: map()
  defp global_pause_status_for_state(%State{globally_paused: paused, global_pause: metadata}) do
    %{globally_paused: paused, paused_at: Map.get(metadata, :paused_at), source: Map.get(metadata, :source)}
  end

  defp global_pause_status_for_state(%State{globally_paused: paused}), do: %{globally_paused: paused, paused_at: nil, source: nil}

  defp normalize_source(source) when is_binary(source) and source != "", do: source
  defp normalize_source(source) when is_atom(source), do: Atom.to_string(source)
  defp normalize_source(_), do: "unknown"
end
