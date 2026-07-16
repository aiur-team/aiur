defmodule Aiur.BuildOrder.TicketHistoryProvider do
  @moduledoc """
  Supervised, bounded projection of safe recent ticket history.

  `Aiur.TicketActivity` remains the owner of current progress and latest safe
  evidence. This provider composes that snapshot with typed Exchange
  observations and `Aiur.IssueLog.event_history/2`. It never reads transcript
  history, agent markdown/NDJSON, terminal panes, or arbitrary model output.

  The provider itself is in-memory. On restart, the IssueLog event markers may
  be queried again, but activity continuity remains `:restart_unknown` until a
  new BO-005 snapshot arrives. This contract deliberately makes no stronger
  replay guarantee than the structured IssueLog API provides.
  """

  use GenServer

  alias Aiur.BuildOrder.TicketHistory.{Failure, Normalizer, Snapshot}
  alias Aiur.BuildOrder.TicketHistoryProvider.Options
  alias Aiur.TrackerIdentity

  @reset_topic "build_order:ticket_history:reset"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec request(TrackerIdentity.t()) :: {:ok, Snapshot.t()} | {:error, Failure.t()}
  def request(identity), do: request(__MODULE__, identity)

  @spec request(GenServer.server(), TrackerIdentity.t()) ::
          {:ok, Snapshot.t()} | {:error, Failure.t()}
  def request(server, identity), do: GenServer.call(server, {:request, identity})

  @spec current(TrackerIdentity.t()) :: {:ok, Snapshot.t()} | {:error, Failure.t()}
  def current(identity), do: current(__MODULE__, identity)

  @spec current(GenServer.server(), TrackerIdentity.t()) ::
          {:ok, Snapshot.t()} | {:error, Failure.t()}
  def current(server, identity), do: GenServer.call(server, {:current, identity})

  @spec snapshots() :: [Snapshot.t()]
  def snapshots, do: snapshots(__MODULE__)

  @spec snapshots(GenServer.server()) :: [Snapshot.t()]
  def snapshots(server), do: GenServer.call(server, :snapshots)

  @spec subscribe(TrackerIdentity.t()) :: :ok | {:error, Failure.t() | term()}
  def subscribe(identity), do: subscribe(__MODULE__, identity)

  @spec subscribe(GenServer.server(), TrackerIdentity.t()) ::
          :ok | {:error, Failure.t() | term()}
  def subscribe(server, identity) do
    with {:ok, subscription_topic} <- GenServer.call(server, {:subscription_topic, identity}),
         :ok <- Phoenix.PubSub.subscribe(Aiur.PubSub, subscription_topic),
         do: Phoenix.PubSub.subscribe(Aiur.PubSub, reset_topic())
  end

  @spec topic(TrackerIdentity.t()) :: String.t()
  def topic(identity) do
    key = TrackerIdentity.github_key(identity)
    "build_order:history:" <> Base.url_encode64(:erlang.term_to_binary(key), padding: false)
  end

  @spec reset_topic() :: String.t()
  def reset_topic, do: @reset_topic

  @impl true
  def init(opts) do
    options = Options.new(opts)

    state = %{
      entries: %{},
      repository: :unavailable,
      configuration_generation: :unknown,
      next_generation: 1,
      access_sequence: 0,
      history_limit: options.history_limit,
      max_identities: options.max_identities,
      stale_after_ms: options.stale_after_ms,
      now: options.now,
      history_fun: options.history_fun,
      activity_snapshot_fun: options.activity_snapshot_fun,
      activity_snapshots_fun: options.activity_snapshots_fun,
      repository_snapshot_fun: options.repository_snapshot_fun,
      reset_epoch: options.reset_epoch
    }

    _ = safely(options.exchange_subscribe_fun)
    _ = safely(options.activity_subscribe_fun)
    _ = safely(fn -> options.configuration_subscribe_fun.(self()) end)

    state = state |> reconcile_repository() |> seed_activity()
    broadcast_reset(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:request, identity}, _from, state) do
    case authorize(state, identity) do
      {:ok, identity} ->
        {entry, state} = refresh(identity, state)
        {:reply, {:ok, snapshot(entry, state)}, state}

      {:error, failure} ->
        {:reply, {:error, failure}, state}
    end
  end

  def handle_call({:current, identity}, _from, state) do
    case authorize(state, identity) do
      {:ok, identity} -> handle_current(identity, state)
      {:error, failure} -> {:reply, {:error, failure}, state}
    end
  end

  def handle_call(:snapshots, _from, state) do
    snapshots =
      state.entries
      |> Map.values()
      |> Enum.sort_by(fn entry -> key(entry.identity) end)
      |> Enum.map(&snapshot(&1, state))

    {:reply, snapshots, state}
  end

  def handle_call({:subscription_topic, identity}, _from, state) do
    case authorize(state, identity) do
      {:ok, identity} -> {:reply, {:ok, topic(identity)}, state}
      {:error, failure} -> {:reply, {:error, failure}, state}
    end
  end

  @impl true
  def handle_info({:event, event}, state) do
    case Normalizer.from_exchange(event) do
      {:ok, identity, history_entry} ->
        case authorize(state, identity) do
          {:ok, identity} ->
            {entry, state} = entry_for_live_event(identity, state)
            {entries, truncated?} = Normalizer.merge_entries(entry.entries, [history_entry], state.history_limit)

            entry = %{
              entry
              | entries: entries,
                history_health: :available,
                truncated?: entry.truncated? or truncated?
            }

            {_entry, state} = store(entry, state)
            {:noreply, state}

          {:error, _failure} ->
            {:noreply, state}
        end

      :ignore ->
        {:noreply, state}
    end
  end

  def handle_info({:ticket_activity_changed, %{identity: %TrackerIdentity{} = identity, snapshot: activity}}, state) do
    case authorize(state, identity) do
      {:ok, identity} ->
        {entry, state} = entry_for_activity(identity, state)
        activity = Normalizer.safe_activity(activity)

        entry = %{
          entry
          | activity: activity,
            activity_health: if(is_map(activity), do: :available, else: :unavailable)
        }

        {_entry, state} = store(entry, state)
        {:noreply, state}

      {:error, _failure} ->
        {:noreply, state}
    end
  end

  def handle_info({:workflow_config_updated, _generation}, state) do
    previous = {state.repository, state.configuration_generation}
    next_state = reconcile_repository(state)

    if {next_state.repository, next_state.configuration_generation} == previous do
      {:noreply, next_state}
    else
      next_state = %{next_state | entries: %{}, reset_epoch: next_state.reset_epoch + 1}
      broadcast_reset(next_state)
      {:noreply, seed_activity(next_state)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_current(identity, state) do
    case Map.fetch(state.entries, key(identity)) do
      {:ok, entry} ->
        {entry, state} = touch(entry, state)
        {:reply, {:ok, snapshot(entry, state)}, put_entry_without_change(entry, state)}

      :error ->
        {:reply, {:ok, missing_snapshot(identity)}, state}
    end
  end

  defp refresh(identity, state) do
    existing = Map.get(state.entries, key(identity), new_entry(identity))
    {history_entries, history_health, source_truncated?} = history(identity, state)
    {activity, activity_health} = activity(identity, state)

    {entries, retained_truncated?} =
      Normalizer.merge_entries(existing.entries, history_entries, state.history_limit)

    entry = %{
      existing
      | activity: activity,
        activity_health: activity_health,
        entries: entries,
        history_health: history_health,
        truncated?: source_truncated? or retained_truncated?
    }

    store(entry, state)
  end

  defp entry_for_live_event(identity, state) do
    case Map.fetch(state.entries, key(identity)) do
      {:ok, entry} -> {entry, state}
      :error -> {new_entry(identity), state}
    end
  end

  defp entry_for_activity(identity, state) do
    case Map.fetch(state.entries, key(identity)) do
      {:ok, entry} -> {entry, state}
      :error -> refresh_history_only(identity, state)
    end
  end

  defp refresh_history_only(identity, state) do
    {history_entries, history_health, truncated?} = history(identity, state)

    {%{
       new_entry(identity)
       | entries: history_entries,
         history_health: history_health,
         truncated?: truncated?
     }, state}
  end

  defp history(identity, state) do
    opts = [kinds: [:emit, :emit_alert, :self], limit: Normalizer.hard_limit()]

    case safely(fn -> state.history_fun.(identity.identifier, opts) end) do
      {:ok, {:error, _reason}} ->
        {[], :unavailable, false}

      {:ok, {:ok, raw_events}} when is_list(raw_events) ->
        normalize_history(raw_events, identity, state)

      {:ok, raw_events} when is_list(raw_events) ->
        normalize_history(raw_events, identity, state)

      _ ->
        {[], :unavailable, false}
    end
  end

  defp normalize_history(raw_events, identity, state) do
    source_truncated? = length(raw_events) >= Normalizer.hard_limit()

    entries =
      raw_events
      |> Enum.take(-Normalizer.hard_limit())
      |> Enum.flat_map(fn event ->
        case Normalizer.from_issue_log(event, identity) do
          {:ok, entry} -> [entry]
          :ignore -> []
        end
      end)

    {entries, trimmed?} = Normalizer.merge_entries([], entries, state.history_limit)
    health = if entries == [], do: :known_empty, else: :available
    {entries, health, source_truncated? or trimmed?}
  end

  defp activity(identity, state) do
    case safely(fn -> state.activity_snapshot_fun.(identity) end) do
      {:ok, {:ok, activity}} -> safe_activity_result(activity)
      {:ok, {:error, :not_found}} -> {nil, :missing_source}
      {:ok, {:error, _reason}} -> {nil, :unavailable}
      {:ok, activity} when is_map(activity) -> safe_activity_result(activity)
      _ -> {nil, :unavailable}
    end
  end

  defp safe_activity_result(activity) do
    case Normalizer.safe_activity(activity) do
      nil -> {nil, :unavailable}
      safe -> {safe, :available}
    end
  end

  defp seed_activity(%{repository: :unavailable} = state), do: state

  defp seed_activity(state) do
    entries =
      case safely(state.activity_snapshots_fun) do
        {:ok, %{entries: entries}} when is_list(entries) -> entries
        _ -> []
      end

    Enum.reduce(entries, state, &seed_activity_entry/2)
  end

  defp seed_activity_entry(activity, state) do
    case field(activity, :identity) do
      %TrackerIdentity{} = identity -> seed_activity_identity(activity, identity, state)
      _ -> state
    end
  end

  defp seed_activity_identity(activity, identity, state) do
    case authorize(state, identity) do
      {:ok, identity} ->
        {entry, state} = refresh_history_only(identity, state)
        safe = Normalizer.safe_activity(activity)
        entry = %{entry | activity: safe, activity_health: if(safe, do: :available, else: :unavailable)}
        {_entry, state} = store(entry, state)
        state

      {:error, _failure} ->
        state
    end
  end

  defp new_entry(identity) do
    %{
      identity: identity,
      generation: :unknown,
      activity: nil,
      activity_health: :missing_source,
      entries: [],
      history_health: :missing_source,
      truncated?: false,
      last_access: 0
    }
  end

  defp store(entry, state) do
    previous = Map.get(state.entries, key(entry.identity))
    {entry, state} = touch(entry, state)

    if same_content?(previous, entry) do
      {entry, put_entry_without_change(entry, state)}
    else
      {state, evicted} = make_room(state, entry.identity)
      entry = %{entry | generation: state.next_generation}

      state = %{
        state
        | entries: Map.put(state.entries, key(entry.identity), entry),
          next_generation: state.next_generation + 1
      }

      Enum.each(evicted, &broadcast_evicted(&1, state))
      broadcast(entry, state)
      {entry, state}
    end
  end

  defp same_content?(nil, _entry), do: false

  defp same_content?(previous, entry) do
    Map.drop(previous, [:last_access]) == Map.drop(entry, [:last_access])
  end

  defp touch(entry, state) do
    sequence = state.access_sequence + 1
    {%{entry | last_access: sequence}, %{state | access_sequence: sequence}}
  end

  defp put_entry_without_change(entry, state) do
    %{state | entries: Map.put(state.entries, key(entry.identity), entry)}
  end

  defp make_room(state, identity) do
    identity_key = key(identity)

    if Map.has_key?(state.entries, identity_key) or map_size(state.entries) < state.max_identities do
      {state, []}
    else
      {evicted_key, evicted} =
        Enum.min_by(state.entries, fn {entry_key, entry} -> {entry.last_access, entry_key} end)

      {%{state | entries: Map.delete(state.entries, evicted_key)}, [evicted]}
    end
  end

  defp snapshot(entry, state) do
    now = now(state)
    observed_at = latest_observation(entry)
    activity_health = activity_source_health(entry, now, state.stale_after_ms)
    freshness = freshness(observed_at, now, state.stale_after_ms)
    health = overall_health(entry, activity_health, freshness)

    %Snapshot{
      identity: entry.identity,
      generation: entry.generation,
      health: health,
      status_label: status_label(health),
      progress: progress(entry.activity),
      latest_evidence: latest_evidence(entry.activity),
      entries: entry.entries,
      truncated?: entry.truncated?,
      observed_at: observed_at,
      freshness: freshness,
      source_health: %{activity: activity_health, history: entry.history_health}
    }
  end

  defp missing_snapshot(identity) do
    %Snapshot{
      identity: identity,
      generation: :unknown,
      health: :missing_source,
      status_label: status_label(:missing_source),
      progress: %{status: :unknown},
      latest_evidence: %{status: :unknown},
      entries: [],
      truncated?: false,
      observed_at: nil,
      freshness: :unknown,
      source_health: %{activity: :missing_source, history: :missing_source}
    }
  end

  defp overall_health(%{history_health: :unavailable}, _activity_health, _freshness), do: :unavailable
  defp overall_health(_entry, :unavailable, _freshness), do: :unavailable
  defp overall_health(%{entries: [_ | _]}, :missing_source, _freshness), do: :restart_unknown
  defp overall_health(_entry, :missing_source, _freshness), do: :missing_source
  defp overall_health(_entry, :stale, _freshness), do: :stale
  defp overall_health(_entry, _activity_health, :stale), do: :stale
  defp overall_health(%{entries: []}, _activity_health, _freshness), do: :known_empty
  defp overall_health(_entry, _activity_health, _freshness), do: :available

  defp activity_source_health(%{activity_health: :available, activity: activity}, now, stale_after_ms) do
    if field(activity, :status) == :stale or freshness(field(activity, :observed_at), now, stale_after_ms) == :stale,
      do: :stale,
      else: :available
  end

  defp activity_source_health(%{activity_health: health}, _now, _stale_after_ms), do: health

  defp freshness(nil, _now, _stale_after_ms), do: :unknown

  defp freshness(%DateTime{} = observed_at, %DateTime{} = now, stale_after_ms) do
    if DateTime.diff(now, observed_at, :millisecond) > stale_after_ms, do: :stale, else: :fresh
  end

  defp latest_observation(entry) do
    activity_time = entry.activity && field(entry.activity, :observed_at)
    entry_time = entry.entries |> List.first() |> then(&(&1 && &1.observed_at))

    case {activity_time, entry_time} do
      {%DateTime{} = left, %DateTime{} = right} -> if(DateTime.compare(left, right) == :lt, do: right, else: left)
      {%DateTime{} = value, _} -> value
      {_, %DateTime{} = value} -> value
      _ -> nil
    end
  end

  defp progress(%{progress: progress}) when is_map(progress), do: progress
  defp progress(_activity), do: %{status: :unknown}
  defp latest_evidence(%{latest_evidence: evidence}) when is_map(evidence), do: evidence
  defp latest_evidence(_activity), do: %{status: :unknown}

  defp status_label(:available), do: "Recent ticket history available"
  defp status_label(:known_empty), do: "No recent structured ticket activity"
  defp status_label(:missing_source), do: "Structured ticket history source missing"
  defp status_label(:restart_unknown), do: "History restored; current activity unknown after restart"
  defp status_label(:stale), do: "Recent ticket history is stale"
  defp status_label(:unavailable), do: "Recent ticket history unavailable"

  defp authorize(%{repository: :unavailable}, _identity),
    do: {:error, %Failure{kind: :configuration}}

  defp authorize(state, %TrackerIdentity{} = identity) do
    cond do
      not TrackerIdentity.joinable?(identity) ->
        {:error, %Failure{kind: :invalid_identity}}

      same_repository?(state.repository, {identity.owner, identity.repository}) ->
        {:ok, identity}

      true ->
        {:error, %Failure{kind: :repository_mismatch}}
    end
  end

  defp authorize(_state, _identity), do: {:error, %Failure{kind: :invalid_identity}}

  defp reconcile_repository(state) do
    case safely(state.repository_snapshot_fun) do
      {:ok, {:ok, {owner, repository}, generation}}
      when is_binary(owner) and is_binary(repository) ->
        %{state | repository: {owner, repository}, configuration_generation: valid_generation(generation)}

      _ ->
        %{state | repository: :unavailable, configuration_generation: :unknown}
    end
  end

  defp valid_generation(generation) when is_integer(generation) and generation > 0, do: generation
  defp valid_generation(_generation), do: :unknown

  defp same_repository?({left_owner, left_repo}, {right_owner, right_repo}) do
    String.downcase(left_owner) == String.downcase(right_owner) and
      String.downcase(left_repo) == String.downcase(right_repo)
  end

  defp broadcast(entry, state) do
    if Process.whereis(Aiur.PubSub) do
      snapshot = snapshot(entry, state)
      Phoenix.PubSub.broadcast(Aiur.PubSub, topic(entry.identity), {:ticket_history_updated, snapshot})
    end
  end

  defp broadcast_evicted(entry, state) do
    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(
        Aiur.PubSub,
        topic(entry.identity),
        {:ticket_history_evicted, entry.identity, state.next_generation}
      )
    end
  end

  defp broadcast_reset(state) do
    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, reset_topic(), {:ticket_history_reset, state.reset_epoch})
    end
  end

  defp safely(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp now(state) do
    case safely(state.now) do
      {:ok, %DateTime{} = now} -> now
      _ -> DateTime.utc_now()
    end
  end

  defp key(identity), do: TrackerIdentity.github_key(identity)
  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_map, _key), do: nil
end
