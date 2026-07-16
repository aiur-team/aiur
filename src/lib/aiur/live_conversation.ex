defmodule Aiur.LiveConversation do
  @moduledoc """
  In-memory, bounded projection of one live agent conversation.

  This is deliberately not a log reader.  A caller supplies an exact runtime
  source (repository-qualified identity, run, attempt, backend and worker
  generation) and trusted structured events.  The projection keeps only the
  small allowlist below, redacts before retaining, and is empty after a daemon
  restart rather than reconstructing a transcript from a workspace.
  """

  use GenServer

  alias Aiur.{Boot, SecretRedactor, TrackerIdentity}

  @version 1
  @message_limit 80
  @body_limit 1_600
  @title_limit 120
  @snapshot_byte_limit 64_000
  @topic "live-conversation:changed"

  @type source :: %{
          required(:identity) => TrackerIdentity.t(),
          required(:attempt_id) => String.t() | integer(),
          required(:backend) => String.t(),
          required(:worker_generation) => pos_integer(),
          optional(:run_id) => String.t(),
          optional(:session_id) => String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec activate(source(), keyword()) :: {:ok, map()} | {:error, atom()}
  def activate(source, opts \\ []), do: call({:activate, source}, opts)

  @spec observe(source(), map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def observe(source, event, opts \\ []) when is_map(event), do: call({:observe, source, event}, opts)

  @spec end_generation(source(), keyword()) :: {:ok, map()} | {:error, atom()}
  def end_generation(source, opts \\ []), do: call({:end, source}, opts)

  @spec mark_unavailable(source(), keyword()) :: {:ok, map()} | {:error, atom()}
  def mark_unavailable(source, opts \\ []), do: call({:unavailable, source}, opts)

  @spec mark_stale(source(), keyword()) :: {:ok, map()} | {:error, atom()}
  def mark_stale(source, opts \\ []), do: call({:stale, source}, opts)

  @spec snapshot(source(), keyword()) :: map()
  def snapshot(source, opts \\ []), do: GenServer.call(server(opts), {:snapshot, source})

  @spec subscribe(source()) :: :ok | {:error, term()}
  def subscribe(source) do
    Phoenix.PubSub.subscribe(Aiur.PubSub, topic_for(source))
  end

  @impl true
  def init(opts), do: {:ok, %{clock: Keyword.get(opts, :clock, &DateTime.utc_now/0), snapshots: %{}, pending_notifications: %{}}}

  @impl true
  def handle_call({:activate, source}, _from, state) do
    with {:ok, key, source} <- canonical_source(source) do
      snapshot = Map.get(state.snapshots, key, fresh_snapshot(source, state.clock.()))
      state = put_snapshot(state, key, snapshot)
      {:reply, {:ok, public(snapshot)}, state}
    else
      _ -> {:reply, {:error, :invalid_source}, state}
    end
  end

  def handle_call({:observe, source, event}, _from, state) do
    with {:ok, key, source} <- canonical_source(source) do
      snapshot = Map.get(state.snapshots, key, fresh_snapshot(source, state.clock.()))
      {snapshot, changed?} = apply_event(snapshot, event, state.clock)
      state = put_snapshot(state, key, snapshot)
      state = if changed?, do: schedule_notification(state, key, source), else: state
      {:reply, {:ok, public(snapshot)}, state}
    else
      _ -> {:reply, {:error, :invalid_source}, state}
    end
  end

  def handle_call({:end, source}, _from, state), do: change_state(source, state, :ended)
  def handle_call({:unavailable, source}, _from, state), do: change_state(source, state, :unavailable)
  def handle_call({:stale, source}, _from, state), do: change_state(source, state, :stale)

  def handle_call({:snapshot, source}, _from, state) do
    case canonical_source(source) do
      {:ok, key, source} ->
        snapshot = Map.get(state.snapshots, key, restart_unknown_snapshot(source, state.clock.()))
        {:reply, public(snapshot), state}

      _ ->
        {:reply, %{version: @version, state: :unavailable, messages: [], diagnostic_counts: %{invalid_source: 1}}, state}
    end
  end

  @impl true
  def handle_info({:notify, key}, state) do
    case Map.pop(state.pending_notifications, key) do
      {nil, pending_notifications} ->
        {:noreply, %{state | pending_notifications: pending_notifications}}

      {source, pending_notifications} ->
        broadcast(source, public(Map.fetch!(state.snapshots, key)))
        {:noreply, %{state | pending_notifications: pending_notifications}}
    end
  end

  defp change_state(source, state, next_state) do
    with {:ok, key, source} <- canonical_source(source) do
      snapshot = Map.get(state.snapshots, key, fresh_snapshot(source, state.clock.()))
      snapshot = %{snapshot | state: next_state, observed_at: state.clock.()}
      state = put_snapshot(state, key, snapshot)
      state = schedule_notification(state, key, source)
      {:reply, {:ok, public(snapshot)}, state}
    else
      _ -> {:reply, {:error, :invalid_source}, state}
    end
  end

  defp apply_event(%{state: state} = snapshot, _event, _clock) when state in [:ended, :unavailable], do: {snapshot, false}

  defp apply_event(snapshot, event, clock) do
    case normalize(event, clock.()) do
      {:ok, message} ->
        apply_message(snapshot, message)

      {:drop, reason} ->
        {put_in(snapshot.diagnostic_counts[reason], Map.get(snapshot.diagnostic_counts, reason, 0) + 1), false}
    end
  end

  # The adapter must make an explicit safe-tool summary opt-in. Existing rich
  # transcript tool/command rows can carry command output, diffs, paths, or
  # provider payloads and therefore never cross this boundary.
  defp normalize(%{kind: kind, id: id, body: body} = event, observed_at)
       when kind in [:assistant_delta, :assistant_completed] and is_binary(id) and is_binary(body) do
    normalized_message(:assistant, body, Map.merge(event, %{msg_id: id, delivery: delivery_for(kind)}), observed_at)
  end

  defp normalize(%{role: role, body: body} = event, observed_at) when role in [:assistant, :user, :system, :tool] and is_binary(body) do
    payload = Map.get(event, :payload) || %{}

    cond do
      role == :tool and Map.get(payload, :safe_summary) != true -> {:drop, :unsafe_tool}
      role == :system and Map.get(payload, :safe_summary) != true -> {:drop, :unsafe_system}
      role == :user and prompt_like?(body) -> {:drop, :prompt}
      true -> normalized_message(role, body, event, observed_at)
    end
  end

  defp normalize(%{"role" => role, "body" => body} = event, observed_at) when is_binary(role) and is_binary(body) do
    normalize(
      %{
        role: String.to_existing_atom(role),
        body: body,
        payload: Map.get(event, "payload"),
        msg_id: Map.get(event, "msg_id"),
        sequence: Map.get(event, "sequence"),
        timestamp: Map.get(event, "timestamp")
      },
      observed_at
    )
  rescue
    ArgumentError -> {:drop, :unknown_kind}
  end

  defp normalize(_event, _observed_at), do: {:drop, :unknown_kind}

  defp normalized_message(role, body, event, observed_at) do
    body = if(Map.get(event, :delivery) == :partial, do: sanitize_fragment(body, @body_limit), else: sanitize(body, @body_limit))

    if body == "" do
      {:drop, :empty}
    else
      id = event[:msg_id] || event[:id] || "#{event[:sequence] || 0}:#{role}:#{:erlang.phash2(body)}"
      occurred_at = date_time(event[:timestamp]) || observed_at

      {:ok,
       %{
         id: to_string(id),
         role: role_name(role),
         title: title_for(role, event),
         body: body,
         occurred_at: occurred_at,
         observed_at: observed_at,
         order: {DateTime.to_unix(occurred_at, :microsecond), to_string(id)},
         delivery: Map.get(event, :delivery, :completed)
       }}
    end
  end

  defp apply_message(snapshot, %{id: id, delivery: :partial} = message) do
    case Map.get(snapshot.seen, id) do
      :completed ->
        {snapshot, false}

      %{body: body} when body == message.body ->
        {snapshot, false}

      %{message_index: index, body: prior_body} ->
        messages = List.update_at(snapshot.messages, index, fn prior -> %{prior | body: sanitize(prior_body <> message.body, @body_limit), observed_at: message.observed_at} end)
        snapshot = %{snapshot | messages: messages, seen: Map.put(snapshot.seen, id, %{message_index: index, body: prior_body <> message.body}), state: :live, observed_at: message.observed_at}
        {snapshot, true}

      nil ->
        {insert_message(snapshot, message), true}
    end
  end

  defp apply_message(snapshot, %{id: id, delivery: :completed} = message) do
    case Map.get(snapshot.seen, id) do
      :completed ->
        {snapshot, false}

      %{message_index: index} ->
        messages = List.replace_at(snapshot.messages, index, message)
        snapshot = %{snapshot | messages: messages, seen: Map.put(snapshot.seen, id, :completed), state: :live, observed_at: message.observed_at}
        {snapshot, true}

      nil ->
        {insert_message(snapshot, message), true}
    end
  end

  defp insert_message(snapshot, message) do
    messages = (snapshot.messages ++ [message]) |> Enum.sort_by(& &1.order)

    seen =
      messages |> Enum.with_index() |> Map.new(fn {%{id: id, delivery: delivery, body: body}, index} -> {id, if(delivery == :completed, do: :completed, else: %{message_index: index, body: body})} end)

    snapshot = %{snapshot | messages: messages, seen: seen, state: :live, observed_at: message.observed_at}
    retain(snapshot)
  end

  defp retain(snapshot) do
    {messages, evicted} = trim_messages(snapshot.messages, 0)

    seen =
      messages |> Enum.with_index() |> Map.new(fn {%{id: id, delivery: delivery, body: body}, index} -> {id, if(delivery == :completed, do: :completed, else: %{message_index: index, body: body})} end)

    %{snapshot | messages: messages, seen: seen, evicted_count: snapshot.evicted_count + evicted, truncated?: snapshot.truncated? or evicted > 0}
  end

  defp trim_messages(messages, evicted) when length(messages) > @message_limit, do: trim_messages(tl(messages), evicted + 1)

  defp trim_messages([_ | rest] = messages, evicted) do
    if snapshot_bytes(messages) > @snapshot_byte_limit,
      do: trim_messages(rest, evicted + 1),
      else: {messages, evicted}
  end

  defp trim_messages([], evicted), do: {[], evicted}

  defp snapshot_bytes(messages), do: messages |> :erlang.term_to_binary() |> byte_size()

  defp fresh_snapshot(source, now) do
    %{version: @version, source: source, state: :known_empty, messages: [], seen: %{}, observed_at: now, diagnostic_counts: %{}, truncated?: false, evicted_count: 0}
  end

  defp restart_unknown_snapshot(source, now), do: %{fresh_snapshot(source, now) | state: :restart_unknown}

  defp public(snapshot) do
    snapshot
    |> Map.take([:version, :source, :state, :messages, :observed_at, :diagnostic_counts, :truncated?, :evicted_count])
    |> Map.update!(:messages, fn messages -> Enum.map(messages, &Map.drop(&1, [:order, :delivery])) end)
  end

  defp canonical_source(%{identity: identity, attempt_id: attempt_id, backend: backend, worker_generation: generation} = source)
       when is_binary(backend) and is_integer(generation) and generation > 0 do
    case TrackerIdentity.github_key(identity) do
      nil ->
        {:error, :invalid_identity}

      identity_key ->
        run_id = Map.get(source, :run_id, Boot.run_id())
        session_id = Map.get(source, :session_id)
        normalized = %{identity: identity, run_id: run_id, attempt_id: to_string(attempt_id), session_id: session_id, backend: backend, worker_generation: generation}
        {:ok, {identity_key, run_id, to_string(attempt_id), session_id, backend, generation}, normalized}
    end
  end

  defp canonical_source(_source), do: {:error, :invalid_source}

  defp sanitize(text, limit) do
    text
    |> sanitize_fragment(limit)
    |> String.trim()
  end

  defp sanitize_fragment(text, limit) do
    text
    |> SecretRedactor.redact()
    |> String.replace(~r{https?://[^\s]+}u, "[REDACTED:url]")
    |> String.replace(~r|(?<![[:alnum:]_])/(?:[^\s/]+/){1,}[^\s]+|u, "[REDACTED:path]")
    |> String.replace(~r/[[:cntrl:]]/u, " ")
    |> String.slice(0, limit)
  end

  defp title_for(role, event) do
    title = event[:title] || role_name(role)
    sanitize(to_string(title), @title_limit)
  end

  defp role_name(:assistant), do: "agent"
  defp role_name(:user), do: "operator"
  defp role_name(:system), do: "system"
  defp role_name(:tool), do: "tool"

  defp delivery_for(:assistant_delta), do: :partial
  defp delivery_for(:assistant_completed), do: :completed

  defp prompt_like?(body), do: String.contains?(body, ["Shared Agent Instructions", "## Workspace setup", "Issue:\n\n", "Description:\n\n"])

  defp date_time(%DateTime{} = value), do: value

  defp date_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _} -> timestamp
      _ -> nil
    end
  end

  defp date_time(_value), do: nil

  defp put_snapshot(state, key, snapshot), do: put_in(state.snapshots[key], snapshot)

  defp schedule_notification(%{pending_notifications: pending} = state, key, source) do
    if Map.has_key?(pending, key) do
      state
    else
      Process.send_after(self(), {:notify, key}, 10)
      %{state | pending_notifications: Map.put(pending, key, source)}
    end
  end

  defp topic_for(source), do: @topic <> ":" <> Integer.to_string(:erlang.phash2(inspect(source)))
  defp broadcast(source, snapshot), do: Phoenix.PubSub.broadcast(Aiur.PubSub, topic_for(source), {:live_conversation_changed, snapshot})
  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
  defp call(message, opts), do: GenServer.call(server(opts), message)
end
