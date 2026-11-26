defmodule Aiur.Executor.HarnessState do
  @moduledoc """
  Reduces Executor hook events into a short-lived view of harness activity.

  Unknown notification types intentionally leave the current state unchanged;
  only notification types established by real-session capture may be added to
  the waiting classification.
  """
  use GenServer
  alias Aiur.Executor.{Session, SessionIngest}

  @ttl_ms 600_000
  @stale_working_ms 60_000
  @notification_waiting MapSet.new([])

  defstruct state: :unknown, last_known: nil, reason: :awaiting_first_hook, observed_at: nil, last_error: nil, notification_type: nil

  @type t :: %__MODULE__{}

  @spec reduce(t(), map(), DateTime.t()) :: t()
  def reduce(%__MODULE__{} = state, %{observed_at: %DateTime{} = at} = event, now) do
    if state.observed_at && DateTime.compare(at, state.observed_at) == :lt do
      state
    else
      transition(state, event, at, now)
    end
  end

  def reduce(%__MODULE__{} = state, _event, _now), do: state

  @spec tick(t(), DateTime.t()) :: t()
  def tick(%__MODULE__{observed_at: nil} = state, _now), do: state

  def tick(%__MODULE__{} = state, now) do
    if DateTime.diff(now, state.observed_at, :millisecond) >= @ttl_ms and state.state != :unknown do
      %{state | state: :unknown, last_known: state.state, reason: :hook_ttl}
    else
      state
    end
  end

  @spec snapshot(t(), DateTime.t()) :: map()
  def snapshot(%__MODULE__{} = state, now) do
    age = if state.observed_at, do: max(DateTime.diff(now, state.observed_at, :millisecond), 0), else: nil

    freshness =
      cond do
        is_nil(state.observed_at) -> :unknown
        state.state == :unknown -> :unknown
        state.state == :working and age > @stale_working_ms -> :stale
        true -> :fresh
      end

    %{
      state: state.state,
      last_known: state.last_known,
      reason: state.reason,
      observed_at: state.observed_at,
      age_ms: age,
      freshness: freshness,
      last_error: state.last_error,
      notification_type: state.notification_type
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    pubsub = Keyword.get(opts, :pubsub, Aiur.PubSub)
    Phoenix.PubSub.subscribe(pubsub, SessionIngest.topic())
    send(self(), :tick)
    {:ok, %{reduced: %__MODULE__{}, pubsub: pubsub, clock: Keyword.get(opts, :clock, &DateTime.utc_now/0), interval: Keyword.get(opts, :interval_ms, 5_000), binding: nil}}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot(state.reduced, state.clock.()), state}
  @impl true
  def handle_info({:executor_hook, event}, state), do: {:noreply, %{state | reduced: reduce(state.reduced, event, state.clock.())}}

  def handle_info(:tick, state) do
    binding = current_binding()
    reduced = if binding == :awaiting, do: %__MODULE__{reason: :awaiting_first_hook}, else: tick(state.reduced, state.clock.())
    if state.interval, do: Process.send_after(self(), :tick, state.interval)
    {:noreply, %{state | reduced: reduced, binding: binding}}
  end

  defp current_binding do
    case Session.current() do
      {:ok, %{state: "awaiting_first_hook"}} -> :awaiting
      {:ok, _binding} -> :attached
      :none -> :none
    end
  catch
    :exit, _ -> :none
  end

  defp transition(state, %{event: "SessionStart"}, at, _now), do: set(state, :idle, at)
  defp transition(state, %{event: event}, at, _now) when event in ["UserPromptSubmit", "PostToolUse"], do: set(state, :working, at)
  defp transition(state, %{event: "Stop", stop_hook_active: true}, _at, _now), do: state
  defp transition(state, %{event: "Stop"}, at, _now), do: set(state, :idle, at)
  defp transition(state, %{event: "StopFailure"} = event, at, _now), do: %{set(state, :idle, at) | last_error: Map.get(event, :reason)}

  defp transition(state, %{event: "Notification", notification_type: type}, at, _now) when is_binary(type) do
    if MapSet.member?(@notification_waiting, type), do: %{set(state, :waiting_for_input, at) | notification_type: type}, else: state
  end

  defp transition(state, %{event: "SessionEnd"}, at, _now), do: set(state, :ended, at)
  defp transition(state, _event, _at, _now), do: state

  defp set(state, next, at), do: %{state | state: next, last_known: next, reason: nil, observed_at: at, last_error: nil, notification_type: nil}
end
