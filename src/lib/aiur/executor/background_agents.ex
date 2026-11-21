defmodule Aiur.Executor.BackgroundAgents do
  @moduledoc """
  In-memory projection of background agents reported by the current Executor binding.

  Finished rows are retained up to 200 per binding generation. A restart starts
  a new observation window; this projection never claims to be a full history.
  """
  use GenServer

  alias Aiur.Executor.Session

  @limit 200

  @type row :: %{
          agent_id: String.t(),
          agent_type: String.t() | nil,
          state: :running | :finished,
          started_at: DateTime.t() | nil,
          stopped_at: DateTime.t() | nil,
          last_message: String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  @spec snapshot() :: {:ok, [row()], DateTime.t()} | {:unsupported, atom()}
  def snapshot do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :snapshot), else: {:unsupported, :no_attached_harness}
  end

  @impl true
  def init(opts) do
    pubsub = Keyword.get(opts, :pubsub, Aiur.PubSub)
    Phoenix.PubSub.subscribe(pubsub, "executor_hook")
    {:ok, %{generation: nil, rows: %{}, order: [], observed_since: DateTime.utc_now(), clock: Keyword.get(opts, :clock, &DateTime.utc_now/0)}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    case support(Session.current()) do
      {:ok, binding} ->
        state = generation(state, binding.generation)
        rows = Enum.map(state.order, &Map.fetch!(state.rows, &1))
        {:reply, {:ok, rows, state.observed_since}, state}

      unsupported ->
        {:reply, unsupported, state}
    end
  end

  @impl true
  def handle_info({:executor_hook, event}, state) do
    case support(Session.current()) do
      {:ok, binding}
      when event.binding_id == binding.binding_id and event.generation == binding.generation and
             event.session_id == binding.provider_session_id ->
        state = generation(state, binding.generation)
        {:noreply, reduce(state, event)}

      _ ->
        {:noreply, state}
    end
  end

  defp support({:ok, %{harness: "claude"} = binding}), do: {:ok, binding}
  defp support({:ok, %{harness: "codex"}}), do: {:unsupported, :fields_unverified}
  defp support(_), do: {:unsupported, :no_attached_harness}

  defp generation(%{generation: generation} = state, generation), do: state
  defp generation(state, generation), do: %{state | generation: generation, rows: %{}, order: [], observed_since: state.clock.()}

  defp reduce(state, %{event: event} = hook) when event in ["SubagentStart", "SubagentStop"] and is_binary(hook.agent_id) and byte_size(hook.agent_id) > 0,
    do: reduce_row(state, event, hook.agent_id, hook)

  defp reduce(state, %{event: event} = hook) when event in ["TaskCreated", "TaskCompleted"] and is_binary(hook.task_id) and byte_size(hook.task_id) > 0,
    do: reduce_row(state, event, hook.task_id, hook)

  defp reduce(state, _hook), do: state

  defp reduce_row(state, event, id, hook) do
    row = Map.get(state.rows, id, %{agent_id: id, agent_type: bounded(hook.agent_type), state: :running, started_at: nil, stopped_at: nil, last_message: nil})
    row = %{row | agent_type: bounded(hook.agent_type) || row.agent_type}

    row =
      case event do
        event when event in ["SubagentStart", "TaskCreated"] -> %{row | state: :running, started_at: hook.observed_at, stopped_at: nil}
        "SubagentStop" -> %{row | state: :finished, started_at: row.started_at, stopped_at: hook.observed_at, last_message: bounded(hook.last_assistant_message)}
        "TaskCompleted" -> %{row | state: :finished, started_at: row.started_at, stopped_at: hook.observed_at}
      end

    order = if id in state.order, do: state.order, else: state.order ++ [id]
    {rows, order} = trim(Map.put(state.rows, id, row), order)
    %{state | rows: rows, order: order}
  end

  defp trim(rows, order) when length(order) <= @limit, do: {rows, order}
  defp trim(rows, [oldest | rest]), do: trim(Map.delete(rows, oldest), rest)

  defp bounded(value) when is_binary(value), do: value |> String.slice(0, 500)
  defp bounded(_value), do: nil
end
