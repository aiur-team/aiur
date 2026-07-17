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
  @ended_generation_limit 16
  @retained_snapshot_limit 128
  @partial_fragment_limit 128
  @diagnostic_count_limit 1_000
  @source_field_limit 256
  @topic "live-conversation:changed"
  @credential_assignment ~r"""
    (?:["']?)
    (?: password | passphrase | api[_-]?key | secret | token | access[_-]?token | refresh[_-]?token | credential )
    (?:["']?) \s* [:=] \s*
    (?: "[^"]*" | '[^']*' | [^\s,}\]]+ )
  """ix

  @type source :: %{
          required(:identity) => TrackerIdentity.t(),
          required(:attempt_id) => String.t() | integer(),
          required(:backend) => String.t(),
          required(:worker_generation) => pos_integer(),
          optional(:run_id) => String.t(),
          optional(:session_id) => String.t()
        }

  @type public_source :: %{
          required(:identity) => map(),
          required(:run_id) => String.t(),
          required(:attempt_id) => String.t(),
          required(:session_id) => String.t() | nil,
          required(:backend) => String.t(),
          required(:worker_generation) => pos_integer()
        }

  @type message :: %{
          required(:id) => String.t(),
          required(:role) => String.t(),
          required(:title) => String.t(),
          required(:body) => String.t(),
          required(:occurred_at) => DateTime.t(),
          required(:observed_at) => DateTime.t()
        }

  @type snapshot :: %{
          required(:version) => pos_integer(),
          required(:source) => public_source() | nil,
          required(:state) => :live | :ended | :known_empty | :stale | :unavailable | :restart_unknown,
          required(:health) => :healthy | :unavailable | :unknown,
          required(:freshness) => :current | :stale | :unknown,
          required(:messages) => [message()],
          required(:observed_at) => DateTime.t(),
          required(:diagnostic_counts) => %{optional(atom()) => non_neg_integer()},
          required(:truncated?) => boolean(),
          required(:evicted_count) => non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec activate(source(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def activate(source, opts \\ []), do: call({:activate, source}, opts)

  @spec observe(source(), map(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def observe(source, event, opts \\ []) when is_map(event), do: call({:observe, source, event}, opts)

  @spec observe_system_transition(source(), map(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def observe_system_transition(source, event, opts \\ []) when is_map(event),
    do: call({:observe_trusted, source, :system, event}, opts)

  @spec observe_operator_message(source(), map(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def observe_operator_message(source, event, opts \\ []) when is_map(event),
    do: call({:observe_trusted, source, :user, event}, opts)

  @spec observe_tool_summary(source(), map(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def observe_tool_summary(source, event, opts \\ []) when is_map(event),
    do: call({:observe_trusted, source, :tool, event}, opts)

  @spec end_generation(source(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def end_generation(source, opts \\ []), do: call({:end, source}, opts)

  @spec mark_unavailable(source(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def mark_unavailable(source, opts \\ []), do: call({:unavailable, source}, opts)

  @spec mark_stale(source(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def mark_stale(source, opts \\ []), do: call({:stale, source}, opts)

  @spec mark_degraded(source(), keyword()) :: {:ok, snapshot()} | {:error, atom()}
  def mark_degraded(source, opts \\ []), do: call({:degraded, source}, opts)

  @spec snapshot(source(), keyword()) :: snapshot()
  def snapshot(source, opts \\ []), do: GenServer.call(server(opts), {:snapshot, source})

  @spec subscribe(source()) :: :ok | {:error, term()}
  def subscribe(source) do
    case canonical_source(source) do
      {:ok, key, _source} -> Phoenix.PubSub.subscribe(Aiur.PubSub, topic_for(key))
      _ -> {:error, :invalid_source}
    end
  end

  @impl true
  def init(opts),
    do: {:ok, %{clock: Keyword.get(opts, :clock, &DateTime.utc_now/0), snapshots: %{}, pending_notifications: %{}}}

  @impl true
  def handle_call({:activate, source}, _from, state) do
    case canonical_source(source) do
      {:ok, key, source} ->
        now = state.clock.()

        {snapshot, changed?} =
          case Map.fetch(state.snapshots, key) do
            {:ok, existing} ->
              activated = activate_snapshot(existing, now)
              {activated, activated != existing}

            :error ->
              {fresh_snapshot(source, now), true}
          end

        state = put_snapshot(state, key, snapshot)
        state = if changed?, do: schedule_notification(state, key, source), else: state
        {:reply, {:ok, public(snapshot)}, state}

      _ ->
        {:reply, {:error, :invalid_source}, state}
    end
  end

  def handle_call({:observe, source, event}, _from, state) do
    case canonical_source(source) do
      {:ok, key, source} ->
        snapshot = Map.get(state.snapshots, key, fresh_snapshot(source, state.clock.()))
        {snapshot, changed?} = apply_event(snapshot, event, state.clock)
        state = put_snapshot(state, key, snapshot)
        state = if changed?, do: schedule_notification(state, key, source), else: state
        {:reply, {:ok, public(snapshot)}, state}

      _ ->
        {:reply, {:error, :invalid_source}, state}
    end
  end

  def handle_call({:observe_trusted, source, role, event}, _from, state)
      when role in [:system, :tool, :user] do
    case canonical_source(source) do
      {:ok, key, source} ->
        snapshot = Map.get(state.snapshots, key, fresh_snapshot(source, state.clock.()))
        {snapshot, changed?} = apply_trusted_event(snapshot, role, event, state.clock)
        state = put_snapshot(state, key, snapshot)
        state = if changed?, do: schedule_notification(state, key, source), else: state
        {:reply, {:ok, public(snapshot)}, state}

      _ ->
        {:reply, {:error, :invalid_source}, state}
    end
  end

  def handle_call({:end, source}, _from, state), do: change_state(source, state, :ended)
  def handle_call({:unavailable, source}, _from, state), do: change_state(source, state, :unavailable)
  def handle_call({:stale, source}, _from, state), do: change_state(source, state, :stale)
  def handle_call({:degraded, source}, _from, state), do: change_state(source, state, :degraded)

  def handle_call({:snapshot, source}, _from, state) do
    case canonical_source(source) do
      {:ok, key, source} ->
        snapshot = Map.get(state.snapshots, key, restart_unknown_snapshot(source, state.clock.()))
        {:reply, public(snapshot), state}

      _ ->
        unavailable = %{
          version: @version,
          source: nil,
          state: :unavailable,
          health: :unavailable,
          freshness: :unknown,
          messages: [],
          observed_at: state.clock.(),
          diagnostic_counts: %{invalid_source: 1},
          truncated?: false,
          evicted_count: 0
        }

        {:reply, unavailable, state}
    end
  end

  @impl true
  def handle_info({:notify, key}, state) do
    case Map.pop(state.pending_notifications, key) do
      {nil, pending_notifications} ->
        {:noreply, %{state | pending_notifications: pending_notifications}}

      {source, pending_notifications} ->
        snapshot =
          case Map.fetch(state.snapshots, key) do
            {:ok, snapshot} -> snapshot
            :error -> restart_unknown_snapshot(source, state.clock.())
          end

        broadcast(key, public(snapshot))
        {:noreply, %{state | pending_notifications: pending_notifications}}
    end
  end

  defp change_state(source, state, next_state) do
    case canonical_source(source) do
      {:ok, key, source} ->
        snapshot = Map.get(state.snapshots, key, fresh_snapshot(source, state.clock.()))

        if snapshot.state == :ended do
          {:reply, {:ok, public(snapshot)}, state}
        else
          next_state = degraded_state(next_state, snapshot)

          snapshot =
            snapshot
            |> Map.merge(%{
              state: next_state,
              health: health_for(next_state),
              freshness: freshness_for(next_state),
              observed_at: state.clock.()
            })
            |> retain()

          state = put_snapshot(state, key, snapshot)
          state = schedule_notification(state, key, source)
          {:reply, {:ok, public(snapshot)}, state}
        end

      _ ->
        {:reply, {:error, :invalid_source}, state}
    end
  end

  defp apply_event(%{state: :ended} = snapshot, _event, _clock), do: {snapshot, false}

  defp apply_event(snapshot, event, clock) do
    case normalize(event, clock.()) do
      {:ok, message} ->
        apply_message(snapshot, message)

      {:drop, reason} ->
        {snapshot |> increment_diagnostic(reason) |> retain(), true}
    end
  end

  defp apply_trusted_event(%{state: :ended} = snapshot, _role, _event, _clock), do: {snapshot, false}

  defp apply_trusted_event(snapshot, role, %{body: body} = event, clock) when is_binary(body) do
    case normalized_message(role, body, event, clock.()) do
      {:ok, message} -> apply_message(snapshot, message)
      {:drop, reason} -> {snapshot |> increment_diagnostic(reason) |> retain(), true}
    end
  end

  defp apply_trusted_event(snapshot, _role, _event, _clock),
    do: {snapshot |> increment_diagnostic(:invalid_summary) |> retain(), true}

  # The adapter must make an explicit safe-tool summary opt-in. Existing rich
  # transcript tool/command rows can carry command output, diffs, paths, or
  # provider payloads and therefore never cross this boundary.
  defp normalize(%{kind: kind, id: id, body: body} = event, observed_at)
       when kind in [:assistant_delta, :assistant_completed] and is_binary(id) and is_binary(body) do
    normalized_message(:assistant, body, Map.merge(event, %{msg_id: id, delivery: delivery_for(kind)}), observed_at)
  end

  defp normalize(%{role: role, body: body} = event, observed_at)
       when role in [:assistant, :user, :system, :tool] and is_binary(body) do
    payload = Map.get(event, :payload) || %{}

    case drop_reason(role, body, payload) do
      {:drop, reason} -> {:drop, reason}
      :keep -> normalized_message(role, body, event, observed_at)
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

  # Tool payloads are intentionally denied here. A producer must add a small,
  # independently-reviewed adapter before tool summaries can cross this
  # boundary; an event-controlled boolean is not trustworthy provenance.
  defp drop_reason(:tool, _body, _payload), do: {:drop, :unsafe_tool}

  defp drop_reason(:system, _body, _payload), do: {:drop, :unsafe_system}

  defp drop_reason(:user, _body, _payload), do: {:drop, :untrusted_operator}

  defp drop_reason(_role, _body, _payload), do: :keep

  defp normalized_message(role, body, event, observed_at) do
    with {:ok, delivery} <- message_delivery(event),
         body <- sanitize_body(body, delivery),
         false <- body == "",
         {:ok, id} <- message_id(role, event, body),
         {:ok, title} <- title_for(role, event) do
      occurred_at = date_time(event[:timestamp]) || observed_at

      {:ok,
       %{
         id: id,
         role: role_name(role),
         title: title,
         body: body,
         occurred_at: occurred_at,
         observed_at: observed_at,
         order: {DateTime.to_unix(occurred_at, :microsecond), id},
         delivery: delivery,
         fragment_ids: fragment_ids(event, body, delivery)
       }}
    else
      true -> {:drop, :empty}
      _ -> {:drop, :invalid_event}
    end
  end

  defp apply_message(snapshot, %{id: id, delivery: :partial} = message) do
    case Map.get(snapshot.seen, id) do
      :completed ->
        {snapshot, false}

      %{message_index: index, body: prior_body, fragment_ids: fragment_ids} ->
        if MapSet.disjoint?(fragment_ids, message.fragment_ids) do
          append_partial_message(snapshot, id, message, index, prior_body, fragment_ids)
        else
          {snapshot, false}
        end

      nil ->
        {insert_message(snapshot, message), true}
    end
  end

  defp apply_message(snapshot, %{id: id, delivery: :completed} = message) do
    case Map.get(snapshot.seen, id) do
      :completed ->
        {snapshot, false}

      %{message_index: index} ->
        prior = Enum.at(snapshot.messages, index)
        message = %{message | occurred_at: prior.occurred_at, order: prior.order}
        messages = List.replace_at(snapshot.messages, index, message)

        snapshot = %{
          live_snapshot(snapshot, message.observed_at)
          | messages: messages,
            seen: Map.put(snapshot.seen, id, :completed)
        }

        {retain(snapshot), true}

      nil ->
        {insert_message(snapshot, message), true}
    end
  end

  defp append_partial_message(snapshot, id, message, index, prior_body, fragment_ids) do
    if MapSet.size(fragment_ids) >= @partial_fragment_limit do
      snapshot =
        snapshot
        |> live_snapshot(message.observed_at)
        |> increment_diagnostic(:partial_fragment_limit)
        |> Map.put(:truncated?, true)
        |> retain()

      {snapshot, true}
    else
      append_bounded_partial(snapshot, id, message, index, prior_body, fragment_ids)
    end
  end

  defp append_bounded_partial(snapshot, id, message, index, prior_body, fragment_ids) do
    accumulated_body = sanitize(prior_body <> message.body, @body_limit)
    fragment_ids = MapSet.union(fragment_ids, message.fragment_ids)

    messages =
      List.update_at(snapshot.messages, index, fn prior ->
        %{prior | body: accumulated_body, observed_at: message.observed_at, fragment_ids: fragment_ids}
      end)

    snapshot = %{
      live_snapshot(snapshot, message.observed_at)
      | messages: messages,
        seen:
          Map.put(snapshot.seen, id, %{
            message_index: index,
            body: accumulated_body,
            fragment_ids: fragment_ids
          })
    }

    {retain(snapshot), true}
  end

  defp insert_message(snapshot, message) do
    messages = (snapshot.messages ++ [message]) |> Enum.sort_by(& &1.order)

    seen =
      messages
      |> Enum.with_index()
      |> Map.new(fn {message, index} -> {message.id, seen_entry(message, index)} end)

    snapshot = %{live_snapshot(snapshot, message.observed_at) | messages: messages, seen: seen}
    retain(snapshot)
  end

  defp retain(snapshot) do
    {messages, evicted} = trim_messages(snapshot, snapshot.messages, 0)

    seen =
      messages
      |> Enum.with_index()
      |> Map.new(fn {message, index} -> {message.id, seen_entry(message, index)} end)

    %{
      snapshot
      | messages: messages,
        seen: seen,
        evicted_count: snapshot.evicted_count + evicted,
        truncated?: snapshot.truncated? or evicted > 0
    }
  end

  defp trim_messages(snapshot, messages, evicted) when length(messages) > @message_limit,
    do: trim_messages(snapshot, tl(messages), evicted + 1)

  defp trim_messages(snapshot, [_ | rest] = messages, evicted) do
    if snapshot_bytes(snapshot, messages, evicted) > @snapshot_byte_limit,
      do: trim_messages(snapshot, rest, evicted + 1),
      else: {messages, evicted}
  end

  defp trim_messages(_snapshot, [], evicted), do: {[], evicted}

  defp snapshot_bytes(snapshot, messages, evicted) do
    snapshot
    |> Map.put(:messages, messages)
    |> Map.update!(:evicted_count, &(&1 + evicted))
    |> Map.update!(:truncated?, &(&1 or evicted > 0))
    |> public()
    |> Jason.encode_to_iodata!()
    |> IO.iodata_length()
  end

  defp fresh_snapshot(source, now) do
    %{
      version: @version,
      source: source,
      state: :known_empty,
      health: :healthy,
      freshness: :current,
      messages: [],
      seen: %{},
      observed_at: now,
      diagnostic_counts: %{},
      truncated?: false,
      evicted_count: 0
    }
  end

  defp health_for(:unavailable), do: :unavailable
  defp health_for(_state), do: :healthy

  defp freshness_for(:stale), do: :stale
  defp freshness_for(state) when state in [:unavailable, :restart_unknown], do: :unknown
  defp freshness_for(_state), do: :current

  defp degraded_state(:degraded, %{messages: []}), do: :unavailable
  defp degraded_state(:degraded, _snapshot), do: :stale
  defp degraded_state(state, _snapshot), do: state

  defp restart_unknown_snapshot(source, now) do
    %{fresh_snapshot(source, now) | state: :restart_unknown, health: :unknown, freshness: :unknown}
  end

  defp activate_snapshot(%{state: :ended} = snapshot, _now), do: snapshot

  defp activate_snapshot(snapshot, now) do
    next_state = if snapshot.messages == [], do: :known_empty, else: :live

    snapshot
    |> Map.merge(%{state: next_state, health: :healthy, freshness: :current, observed_at: now})
    |> retain()
  end

  defp live_snapshot(snapshot, observed_at) do
    %{snapshot | state: :live, health: :healthy, freshness: :current, observed_at: observed_at}
  end

  defp public(snapshot) do
    snapshot
    |> Map.take([
      :version,
      :source,
      :state,
      :health,
      :freshness,
      :messages,
      :observed_at,
      :diagnostic_counts,
      :truncated?,
      :evicted_count
    ])
    |> Map.update!(:messages, fn messages ->
      Enum.map(messages, &Map.drop(&1, [:order, :delivery, :fragment_ids]))
    end)
  end

  defp canonical_source(source) when is_map(source) do
    case source do
      %{identity: identity, attempt_id: attempt_id, backend: backend, worker_generation: generation} ->
        canonical_source(identity, attempt_id, backend, generation, source)

      _ ->
        {:error, :invalid_source}
    end
  end

  defp canonical_source(_source), do: {:error, :invalid_source}

  defp canonical_source(identity, attempt_id, backend, generation, source)
       when (is_binary(attempt_id) or is_integer(attempt_id)) and is_binary(backend) and backend != "" and
              is_integer(generation) and generation > 0 do
    case TrackerIdentity.github_key(identity) do
      nil ->
        {:error, :invalid_identity}

      identity_key ->
        run_id = Map.get(source, :run_id, Boot.run_id())
        session_id = Map.get(source, :session_id)
        attempt_id = to_string(attempt_id)
        public_identity = public_identity(identity)
        public_session_id = public_session_id(session_id)

        if valid_public_source?(public_identity, run_id, attempt_id, session_id, backend) do
          normalized = %{
            identity: public_identity,
            run_id: run_id,
            attempt_id: attempt_id,
            session_id: public_session_id,
            backend: backend,
            worker_generation: generation
          }

          {:ok, {identity_key, run_id, attempt_id, session_id, backend, generation}, normalized}
        else
          {:error, :invalid_source}
        end
    end
  end

  defp canonical_source(_identity, _attempt_id, _backend, _generation, _source),
    do: {:error, :invalid_source}

  defp public_identity(identity) do
    Map.take(identity, [:version, :kind, :owner, :repository, :identifier])
  end

  # Session/thread identifiers are provider-controlled values. They remain in
  # the private key for exact-generation isolation, but the public contract
  # receives only an opaque surrogate.
  defp public_session_id(nil), do: nil
  defp public_session_id(session_id), do: opaque_id("session:", session_id)

  defp valid_public_source?(identity, run_id, attempt_id, session_id, backend) do
    identity_fields = Map.take(identity, [:owner, :repository, :identifier]) |> Map.values()

    Enum.all?(identity_fields ++ [run_id, attempt_id, backend], &safe_source_field?/1) and
      safe_optional_source_field?(session_id)
  end

  defp safe_source_field?(value) when is_binary(value) do
    String.length(value) <= @source_field_limit and sanitize(value, @source_field_limit) == value
  end

  defp safe_source_field?(_value), do: false

  defp safe_optional_source_field?(nil), do: true
  defp safe_optional_source_field?(value), do: safe_source_field?(value)

  defp sanitize(text, limit) do
    text
    |> sanitize_fragment(limit)
    |> String.trim()
  end

  defp sanitize_fragment(text, limit) do
    text
    |> String.replace_invalid()
    |> SecretRedactor.redact()
    |> String.replace(@credential_assignment, "[REDACTED:credential]")
    |> String.replace(~r{https?://[^\s]+}u, "[REDACTED:url]")
    |> String.replace(~r|(?<![[:alnum:]_])/(?:[^\s/]+/){1,}[^\s]+|u, "[REDACTED:path]")
    |> String.replace(~r{(?:[A-Za-z]:\\|~[/\\])[^\s]+}u, "[REDACTED:path]")
    |> String.replace(~r/\b[A-Z][A-Z0-9_]{2,}=(?:[^\s]+)/u, "[REDACTED:env]")
    |> String.replace(~r{\b(?:Bearer|Basic)\s+[^\s]+}iu, "[REDACTED:credential]")
    |> String.replace(~r/[[:cntrl:]]/u, " ")
    |> String.slice(0, limit)
  end

  defp sanitize_body(body, :partial), do: sanitize_fragment(body, @body_limit)
  defp sanitize_body(body, :completed), do: sanitize(body, @body_limit)

  defp message_delivery(event) do
    case Map.get(event, :delivery, :completed) do
      delivery when delivery in [:partial, :completed] -> {:ok, delivery}
      _ -> {:error, :invalid_delivery}
    end
  end

  defp message_id(role, event, body) do
    case event[:msg_id] || event[:id] do
      nil -> {:ok, stable_id(role, event, body)}
      "" -> {:ok, stable_id(role, event, body)}
      id when is_binary(id) or is_integer(id) -> {:ok, opaque_id("message:", id)}
      _ -> {:error, :invalid_id}
    end
  end

  defp title_for(role, event) do
    case event[:title] do
      nil -> {:ok, role_name(role)}
      title when is_binary(title) -> sanitized_title(title, role)
      title when is_atom(title) -> sanitized_title(Atom.to_string(title), role)
      _ -> {:error, :invalid_title}
    end
  end

  defp sanitized_title(title, role) do
    case sanitize(title, @title_limit) do
      "" -> {:ok, role_name(role)}
      title -> {:ok, title}
    end
  end

  defp role_name(:assistant), do: "agent"
  defp role_name(:user), do: "operator"
  defp role_name(:system), do: "system"
  defp role_name(:tool), do: "tool"

  defp delivery_for(:assistant_delta), do: :partial
  defp delivery_for(:assistant_completed), do: :completed

  defp date_time(%DateTime{} = value), do: value

  defp date_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _} -> timestamp
      _ -> nil
    end
  end

  defp date_time(_value), do: nil

  defp put_snapshot(state, key, snapshot) do
    snapshots =
      state.snapshots
      |> Map.put(key, snapshot)
      |> retain_ended_generations()
      |> retain_snapshots()

    %{state | snapshots: snapshots}
  end

  defp retain_ended_generations(snapshots) do
    ended =
      snapshots
      |> Enum.filter(fn {_key, snapshot} -> snapshot.state == :ended end)
      |> Enum.sort_by(&retention_order/1)

    ended
    |> Enum.take(max(length(ended) - @ended_generation_limit, 0))
    |> Enum.reduce(snapshots, fn {key, _snapshot}, acc -> Map.delete(acc, key) end)
  end

  defp retain_snapshots(snapshots) when map_size(snapshots) <= @retained_snapshot_limit,
    do: snapshots

  defp retain_snapshots(snapshots) do
    snapshots
    |> Enum.sort_by(&retention_order/1)
    |> Enum.take(map_size(snapshots) - @retained_snapshot_limit)
    |> Enum.reduce(snapshots, fn {key, _snapshot}, acc -> Map.delete(acc, key) end)
  end

  defp retention_order({key, snapshot}),
    do: {DateTime.to_unix(snapshot.observed_at, :microsecond), inspect(key)}

  defp schedule_notification(%{pending_notifications: pending} = state, key, source) do
    if Map.has_key?(pending, key) do
      state
    else
      Process.send_after(self(), {:notify, key}, 10)
      %{state | pending_notifications: Map.put(pending, key, source)}
    end
  end

  defp stable_id(role, event, body) do
    source_id = event[:turn_id] || event[:timestamp] || event[:occurred_at] || ""
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({role, source_id, body})) |> Base.url_encode64(padding: false)
    "derived:" <> digest
  end

  defp fragment_ids(event, body, delivery) do
    if delivery == :partial do
      fragment_id = fragment_id(event, body)
      MapSet.new([fragment_id])
    else
      MapSet.new()
    end
  end

  defp fragment_id(%{sequence: sequence}, _body)
       when is_integer(sequence) or (is_binary(sequence) and byte_size(sequence) <= @source_field_limit),
       do: opaque_id("fragment:", sequence)

  defp fragment_id(event, body), do: stable_id(:fragment, event, body)

  defp opaque_id(prefix, value) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.url_encode64(padding: false)
    prefix <> digest
  end

  defp seen_entry(%{delivery: :completed}, _index), do: :completed

  defp seen_entry(%{body: body, fragment_ids: fragment_ids}, index),
    do: %{message_index: index, body: body, fragment_ids: fragment_ids}

  defp increment_diagnostic(snapshot, reason) do
    count = Map.get(snapshot.diagnostic_counts, reason, 0)

    if count < @diagnostic_count_limit do
      put_in(snapshot.diagnostic_counts[reason], count + 1)
    else
      %{snapshot | truncated?: true}
    end
  end

  defp topic_for(key) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(key)) |> Base.url_encode64(padding: false)
    @topic <> ":v#{@version}:" <> digest
  end

  defp broadcast(key, snapshot),
    do: Phoenix.PubSub.broadcast(Aiur.PubSub, topic_for(key), {:live_conversation_changed, snapshot})

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
  defp call(message, opts), do: GenServer.call(server(opts), message)
end
