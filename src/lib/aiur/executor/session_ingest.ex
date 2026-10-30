defmodule Aiur.Executor.SessionIngest do
  @moduledoc """
  Asynchronous Executor hook sink. Only accepted hooks update the binding and
  broadcast `{:executor_hook, event}` on `executor_hook` via Aiur.PubSub.
  Raw HTTP payloads are normalized inside the worker so path validation and
  Session persistence never block the hook response. Each binding admits 50/s.
  """
  use GenServer
  alias Aiur.Executor.{HookPayload, Session}

  @spec topic() :: String.t()
  def topic, do: "executor_hook"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  @spec dispatch(map()) :: :ok
  def dispatch(event), do: GenServer.cast(__MODULE__, {:event, event})
  @spec dispatch(map(), term()) :: :ok
  def dispatch(raw, harness), do: GenServer.cast(__MODULE__, {:raw, raw, harness})
  @spec rejected_counts() :: map()
  def rejected_counts, do: GenServer.call(__MODULE__, :counts)

  @impl true
  def init(opts), do: {:ok, %{window: nil, counts: %{}, clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end), pubsub: Keyword.get(opts, :pubsub, Aiur.PubSub)}}
  @impl true
  def handle_call(:counts, _from, state), do: {:reply, state.counts, state}
  @impl true
  def handle_cast({:raw, raw, harness}, state), do: admit(state, fn -> HookPayload.normalize(raw, harness) end)
  def handle_cast({:event, event}, state), do: admit(state, fn -> {:ok, event} end)

  defp admit(state, normalize) do
    with {:ok, binding} <- attached(),
         {:ok, state} <- rate_limit(state, binding.binding_id) do
      {:noreply, ingest(state, binding, normalize.())}
    else
      {:error, reason, state} -> {:noreply, reject(state, reason)}
      {:error, reason} -> {:noreply, reject(state, reason)}
    end
  end

  defp attached do
    case Session.current() do
      {:ok, %{state: status} = binding} when status in ["awaiting_first_hook", "attached"] -> {:ok, binding}
      _ -> {:error, :not_attached}
    end
  end

  defp rate_limit(state, id) do
    now = state.clock.()

    case state.window do
      {^id, start, count} when now - start < 1000 and count >= 50 -> {:error, :rate_limited, state}
      {^id, start, count} when now - start < 1000 -> {:ok, %{state | window: {id, start, count + 1}}}
      _ -> {:ok, %{state | window: {id, now, 1}}}
    end
  end

  defp ingest(state, _binding, {:error, reason}), do: reject(state, reason)

  defp ingest(state, binding, {:ok, event}) do
    with :ok <- same_harness(binding, event),
         {:ok, bound} <- bind(binding, event),
         {:ok, _} <- finish(bound.binding_id, event) do
      Phoenix.PubSub.broadcast(state.pubsub, topic(), {:executor_hook, event})
      state
    else
      {:error, reason} -> reject(state, reason)
    end
  end

  defp same_harness(%{harness: harness}, %{harness: harness}), do: :ok
  defp same_harness(_binding, _event), do: {:error, :foreign_session}

  defp bind(%{binding_id: id, provider_session_id: previous}, %{event: "SessionStart", source: source} = event) when not is_nil(previous) and source in ["resume", "clear", "compact", "fork"],
    do: Session.rebind_on_session_start(id, event)

  defp bind(%{binding_id: id}, %{event: "SessionEnd", reason: "clear"} = event), do: Session.prepare_clear_rebind(id, event)

  defp bind(%{binding_id: id}, event), do: Session.bind_provider_session(id, event)
  defp finish(_id, %{event: "SessionEnd", reason: "clear"}), do: {:ok, :pending_clear}
  defp finish(id, %{event: "SessionEnd"}), do: Session.detach(id, "stopped")
  defp finish(id, event), do: Session.touch(id, event.observed_at)

  defp reject(state, reason) do
    HookPayload.count(reason)
    %{state | counts: Map.update(state.counts, reason, 1, &(&1 + 1))}
  end
end
