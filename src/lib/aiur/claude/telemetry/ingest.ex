defmodule Aiur.Claude.Telemetry.Ingest do
  @moduledoc false
  # The authenticated `:ingest` body of `Aiur.Claude.Telemetry`: correlation
  # and replay checks, the resolved-model rule, and publication. Pure over the
  # receiver state map; the GenServer stays in `Aiur.Claude.Telemetry`.

  alias Aiur.Claude.Telemetry.{Event, LaunchRegistry, UsageAdapter}

  @topic "claude_telemetry:events"
  @usage_topic "claude_telemetry:usage"

  @doc false
  @spec ingest_authenticated(map(), String.t(), map(), map()) :: {:reply, :ok | {:error, atom()}, map()}
  def ingest_authenticated(state, capability, entry, payload) do
    with {:ok, events} <-
           Event.from_otlp(payload, entry.correlation, request_source_contract(entry.source_contract, capability)),
         :ok <- matching_session(entry, events),
         :ok <- unseen?(state.replay, events),
         {:ok, next_entry} <- LaunchRegistry.take_rate_slots(entry, state, length(events) - 1) do
      events =
        Enum.map(events, fn event ->
          %{event | correlation: Map.put(event.correlation, :producer_generation, entry.correlation.producer_generation)}
        end)

      next_entry =
        %{next_entry | session_id: events |> hd() |> get_in([:correlation, :session_id])}
        |> report_resolved_model(events)

      next =
        state
        |> put_in([:capabilities, capability], next_entry)
        |> remember(events)
        |> Map.update!(:accepted, &(&1 + length(events)))

      Enum.each(events, &publish/1)
      {:reply, :ok, next}
    else
      {:error, {:coverage, reason, class, field}} ->
        publish_ingest_coverage(entry, class, field)
        {:reply, {:error, reason}, LaunchRegistry.count_rejection(state, reason)}

      {:error, reason} ->
        {:reply, {:error, reason}, LaunchRegistry.count_rejection(state, reason)}
    end
  end

  # A route names a backend and at most a model tag; the concrete version that
  # answered is only ever reported by the running agent. Every authenticated
  # API-request event carries it, so the first one to name a model — and any
  # later one that names a different model, which is what a mid-session
  # fallback looks like — tells the orchestrator what its running entry is
  # actually executing on.
  @doc false
  @spec report_resolved_model(map(), [Event.t()]) :: map()
  def report_resolved_model(%{execution_recipient: recipient, issue_id: issue_id} = entry, events)
      when is_pid(recipient) and is_binary(issue_id) do
    case observed_model(events) do
      nil ->
        entry

      model when model == entry.resolved_model ->
        entry

      model ->
        send(recipient, {:session_resolved_model, issue_id, model})
        %{entry | resolved_model: model}
    end
  end

  def report_resolved_model(entry, _events), do: entry

  @doc false
  @spec observed_model(term()) :: term()
  def observed_model(events) do
    Enum.find_value(events, fn event ->
      case event |> Map.get(:attributes, %{}) |> Map.get("model") do
        model when is_binary(model) and model != "" -> model
        _absent -> nil
      end
    end)
  end

  @doc false
  @spec matching_session(term(), term()) :: term()
  def matching_session(%{session_id: current}, events) when is_list(events) do
    session_ids = events |> Enum.map(&get_in(&1, [:correlation, :session_id])) |> Enum.uniq()

    cond do
      length(session_ids) != 1 -> {:error, :stale_session}
      is_nil(current) -> :ok
      session_ids == [current] -> :ok
      true -> {:error, :stale_session}
    end
  end

  @doc false
  @spec unseen?(term(), term()) :: term()
  def unseen?(%{set: set}, events) when is_list(events) do
    keys = Enum.map(events, &Event.replay_key/1)

    if Enum.any?(keys, &MapSet.member?(set, &1)) or MapSet.size(MapSet.new(keys)) != length(keys), do: {:error, :replay}, else: :ok
  end

  @spec remember(term(), term()) :: term()
  def remember(state, events) do
    {queue, set} =
      Enum.reduce(events, {state.replay.queue, state.replay.set}, fn event, {queue, set} ->
        key = Event.replay_key(event)
        {:queue.in(key, queue), MapSet.put(set, key)}
      end)

    {queue, set} = trim_replay(queue, set, state.replay_capacity)
    %{state | replay: %{queue: queue, set: set}}
  end

  @doc false
  @spec trim_replay(term(), term(), term()) :: term()
  def trim_replay(queue, set, max) do
    if :queue.len(queue) > max do
      {{:value, dropped}, queue} = :queue.out(queue)
      trim_replay(queue, MapSet.delete(set, dropped), max)
    else
      {queue, set}
    end
  end

  @doc false
  @spec broadcast(term()) :: term()
  def broadcast(event) do
    if Process.whereis(Aiur.PubSub), do: Phoenix.PubSub.broadcast(Aiur.PubSub, @topic, {:claude_telemetry, event})
    :ok
  end

  @doc false
  @spec publish(term()) :: term()
  def publish(%{correlation: %{backend: "claude-repl"}} = event) do
    :ok = broadcast(event)

    case UsageAdapter.normalize(event, DateTime.utc_now()) do
      {:ok, envelope, coverage} ->
        broadcast_usage({:claude_usage, envelope})
        Enum.each(coverage, &broadcast_usage({:claude_usage_coverage, &1}))

      {:coverage, coverage} ->
        broadcast_usage({:claude_usage_coverage, coverage})
    end
  end

  def publish(event), do: broadcast(event)

  @doc false
  @spec publish_ingest_coverage(term(), term(), term()) :: term()
  def publish_ingest_coverage(%{correlation: %{backend: "claude-repl"}}, class, field) do
    broadcast_usage({:claude_usage_coverage, UsageAdapter.coverage(class, field)})
  end

  def publish_ingest_coverage(_entry, _class, _field), do: :ok

  @spec broadcast_usage(term()) :: term()
  def broadcast_usage(message) do
    if Process.whereis(Aiur.PubSub), do: Phoenix.PubSub.broadcast(Aiur.PubSub, @usage_topic, message)
    :ok
  end

  @spec request_source_contract(term(), term()) :: term()
  def request_source_contract(source_contract, capability) do
    Map.put(source_contract, :forbidden_values, [
      capability,
      "Bearer #{capability}",
      "Authorization=Bearer #{capability}"
    ])
  end
end
