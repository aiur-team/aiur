defmodule Aiur.ProgressCheckin.Worker do
  @moduledoc """
  Periodic check-in: every `interval_ms` (default 5 minutes), publish
  `ticket.<id>.operator.progress_request` for each active agent so it
  emits a 1–10 progress estimate at the next turn boundary.

  Delivery rides the standard event bus:

      Aiur.Events.Publisher.publish(
        "ticket.<id>.operator.progress_request",
        %{...}
      )

  Agents auto-subscribe to that topic via
  `Aiur.Events.UniversalSubscriptions`, so the request lands in the
  existing subscription drain alongside firehose events. It is
  **non-interruptive**: the request is read at the next natural turn
  boundary, never interrupting an active tool call.

  The agent's reply is an emitted `progress.checkin` event, which the
  source-aware ratchet in `Aiur.AgentList.App.record_progress_sample/2`
  treats as the new floor.
  """

  use GenServer

  require Logger

  alias Aiur.Events.Publisher
  alias Aiur.Orchestrator

  @default_interval_ms 5 * 60 * 1_000

  @doc """
  Start the worker. Accepts:

    * `:interval_ms` — tick period in milliseconds (default 5 min).
    * `:orchestrator` — server reference for active-identifier lookups
      (default `Aiur.Orchestrator`).
    * `:publisher` — module/function tuple for tests to capture the
      publish call instead of going through the real Exchange. When
      omitted, publishes via `Aiur.Events.Publisher.publish/3`.
    * `:start_paused?` — when `true`, the worker does not schedule
      the first tick automatically. Tests drive it via `:tick`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      orchestrator: Keyword.get(opts, :orchestrator, Aiur.Orchestrator),
      publisher: Keyword.get(opts, :publisher),
      start_paused?: Keyword.get(opts, :start_paused?, false)
    }

    unless state.start_paused?, do: schedule_tick(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    identifiers =
      try do
        Orchestrator.list_running_active_identifiers(state.orchestrator, 1_000)
      rescue
        _ -> []
      end

    Enum.each(identifiers, fn id ->
      publish_request(state, id)
    end)

    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  defp schedule_tick(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp publish_request(state, identifier) when is_binary(identifier) do
    topic = "ticket." <> identifier <> ".operator.progress_request"

    payload = %{
      "source" => "operator",
      "kind" => "progress_request",
      "message" =>
        "Executor check-in: emit `progress.checkin` with your current 1–10 progress estimate as %{percent: N*10}. Do not change your work plan or ask questions — this is a silent status ping."
    }

    case state.publisher do
      nil ->
        Publisher.publish(topic, payload)

      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        apply(mod, fun, [topic, payload])

      fun when is_function(fun, 2) ->
        fun.(topic, payload)
    end
  end

  defp publish_request(_state, _identifier), do: :ok
end
