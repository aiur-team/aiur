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

  alias Aiur.Orchestrator.{PauseResume, State, StatusReport}

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

  @doc """
  Flip the global pause switch. `true` pauses the daemon and holds all running
  agents; `false` unpauses and resumes only the globally held agents. Idempotent.
  """
  @spec set_global_pause(boolean()) :: {:ok, map()} | {:error, term()}
  def set_global_pause(on?) when is_boolean(on?), do: set_global_pause(Aiur.Orchestrator, on?)

  @spec set_global_pause(GenServer.server(), boolean()) :: {:ok, map()} | {:error, term()}
  def set_global_pause(server, on?) when is_boolean(on?) do
    if GenServer.whereis(server) do
      GenServer.call(server, {:set_global_pause, on?}, @call_timeout)
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
  def set_global_pause_call(%State{globally_paused: current} = state, on?) when is_boolean(on?) do
    state =
      cond do
        on? and not current ->
          PauseResume.pause_running_for_global(%{state | globally_paused: true})

        not on? and current ->
          PauseResume.resume_running_from_global(%{state | globally_paused: false})

        true ->
          state
      end

    StatusReport.notify_dashboard(state)
    {:reply, {:ok, global_pause_status(state)}, state}
  end

  @doc "Projection of the global pause switch for status reports and control replies."
  @spec global_pause_status(State.t()) :: %{globally_paused: boolean()}
  def global_pause_status(%State{globally_paused: paused}), do: %{globally_paused: paused}
end
