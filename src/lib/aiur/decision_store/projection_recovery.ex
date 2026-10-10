defmodule Aiur.DecisionStore.ProjectionRecovery do
  @moduledoc false

  alias Aiur.{Signal, Decision, DecisionEvent, DecisionProjection, JsonStore}
  alias AiurWeb.OperatorControlCenter.UnitsPresentation
  require Logger

  @spec initialize(map(), list()) :: map()
  def initialize(state, records) do
    checkpoint = checkpoint(state.projection_path)
    marker = Map.get(checkpoint, "last_event_id", :legacy)
    pending_ids = MapSet.new(pending_ids(checkpoint) ++ after_marker(records, marker))
    {_, pending} = Enum.reduce(records, {%{}, []}, &replay_record(&1, &2, pending_ids))
    Map.merge(state, %{pending_notifications: Enum.reverse(pending), last_event_id: last_id(records), projection_retry: nil, projection: :healthy})
  end

  defp after_marker(_records, :legacy), do: []
  defp after_marker(records, nil), do: Enum.map(records, &Map.get(&1, :event_id))

  defp after_marker(records, marker) do
    case Enum.split_while(records, &(Map.get(&1, :event_id) != marker)) do
      {_prefix, [_marked | tail]} -> Enum.map(tail, &Map.get(&1, :event_id))
      {_prefix, []} -> Enum.map(records, &Map.get(&1, :event_id))
    end
  end

  defp checkpoint(path) do
    case JsonStore.read(path, %{"last_event_id" => nil}) do
      {:ok, %{"decisions" => decisions} = value} when is_list(decisions) -> value
      {:ok, %{"last_event_id" => nil} = value} -> value
      _unreadable -> %{"last_event_id" => nil}
    end
  end

  defp pending_ids(checkpoint) do
    case Map.get(checkpoint, "pending_notification_ids", []) do
      ids when is_list(ids) -> ids
      _invalid -> []
    end
  end

  defp replay_record(%Decision{} = decision, {current, pending}, _ids),
    do: {Map.put(current, decision.decision_id, decision), pending}

  defp replay_record(%DecisionEvent{} = event, {current, pending}, ids) do
    prior = Map.get(current, event.decision_id)
    decision = DecisionProjection.reduce(List.wrap(prior) ++ [event]).current[event.decision_id]
    withheld? = MapSet.member?(ids, event.event_id)
    pending = if withheld?, do: [{decision, event} | pending], else: pending
    {Map.put(current, event.decision_id, decision), pending}
  end

  defp replay_record(_unknown, acc, _ids), do: acc

  defp last_id(records) do
    Enum.reduce(records, nil, fn record, id -> Map.get(record, :event_id, id) end)
  end

  @spec enqueue(map(), Decision.t(), DecisionEvent.t()) :: map()
  def enqueue(state, decision, event) do
    %{state | pending_notifications: state.pending_notifications ++ [{decision, event}], last_event_id: event.event_id}
  end

  @spec repair(map(), (Decision.t(), DecisionEvent.t(), map() -> term())) :: map()
  def repair(%{projection_path: nil} = state, _notify), do: state

  def repair(%{writable?: false} = state, _notify) do
    _ = write(state)
    state
  end

  def repair(state, notify) do
    case write(state) do
      :ok -> drain(state, notify)
      {:error, reason} -> stale(state, reason)
    end
  end

  defp drain(state, notify) do
    Enum.each(state.pending_notifications, fn {decision, event} -> notify.(decision, event, state) end)
    cleared = %{state | pending_notifications: []}
    # Keep IDs durable until sends finish; a crash can repeat an ID, never lose it.
    result = if state.pending_notifications == [], do: :ok, else: write(cleared)

    case result do
      :ok -> healthy(cleared)
      {:error, reason} -> stale(cleared, reason)
    end
  end

  defp write(state) do
    projection = DecisionProjection.serialize_current(state.current)
    ids = Enum.map(state.pending_notifications, fn {_decision, event} -> event.event_id end)
    JsonStore.write!(state.projection_path, Map.merge(projection, %{"last_event_id" => state.last_event_id, "pending_notification_ids" => ids}))
    File.chmod!(state.projection_path, 0o600)
    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp healthy(state) do
    if state.projection_retry, do: Process.cancel_timer(state.projection_retry)
    if match?({:projection_stale, _}, state.health), do: send(self(), :decision_projection_recovered)
    %{state | health: :writable, projection_retry: nil, projection: :healthy}
  end

  defp stale(state, reason) do
    since =
      case state.projection do
        {:stale, since, _reason} -> since
        _healthy -> DateTime.utc_now()
      end

    unless match?({:stale, _, _}, state.projection) do
      Logger.error("aiur_decision_store phase=projection_repair_failed reason=#{inspect(reason)}")

      Signal.agent_alert("decision_store.repair_failed", "Decision projection stale since #{DateTime.to_iso8601(since)}; journal remains authoritative and writable.",
        reason: inspect(reason),
        needs_attention: true
      )
    end

    timer = state.projection_retry || Process.send_after(self(), :repair_decision_projection, 1_000)
    %{state | health: {:projection_stale, since}, projection_retry: timer, projection: {:stale, since, reason}}
  end

  @spec cursor_id(DecisionEvent.t()) :: pos_integer() | String.t()
  def cursor_id(event) do
    case DecisionEvent.parse_provenance_event_id(event.event_id) do
      {:ok, id} -> id
      :error -> event.event_id
    end
  end

  @spec label(term()) :: String.t()
  def label({:projection_stale, %DateTime{} = since}) do
    age = max(DateTime.diff(DateTime.utc_now(), since), 0)
    "Decision projection stale since #{DateTime.to_iso8601(since)} (age #{UnitsPresentation.age_label(age)})"
  end

  def label({:projection_stale, _unknown}), do: "Decision projection stale since unknown (age unknown)"
  def label(:writable), do: "Decision projection healthy"
  def label(other), do: "Decision store unavailable: #{inspect(other)}"

  @spec print_status(GenServer.server()) :: :ok
  def print_status(store \\ Aiur.DecisionStore) do
    IO.puts(label(Aiur.DecisionStore.health(store)))
  catch
    :exit, _reason -> IO.puts("Decision store unavailable")
  end
end
