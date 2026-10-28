defmodule Aiur.Conversation.Journal do
  @moduledoc "Serialized, recoverable writer for one conversation. All disk work stays in this process."
  use GenServer, restart: :transient
  alias Aiur.Config.Paths
  alias Aiur.Conversation.{Entry, Ingest, JournalImport, JournalSessions, ProviderReplay, Ref}

  @spec start_link(Ref.t()) :: GenServer.on_start()
  def start_link(ref), do: GenServer.start_link(__MODULE__, ref, name: via(ref))

  @spec via(Ref.t()) :: {:via, Registry, {atom(), String.t()}}
  def via(ref), do: {:via, Registry, {Aiur.Conversation.Registry, Ref.conversation_id(ref)}}

  @impl true
  def init(ref) do
    Process.flag(:trap_exit, true)
    opts = Application.get_env(:aiur, :conversation_journal, [])
    {failed_since, dropped_span} = :persistent_term.get({__MODULE__, Ref.conversation_id(ref), :pending_gaps}, {nil, nil})

    state = %{
      ref: ref,
      id: Ref.conversation_id(ref),
      dir: nil,
      segment_state: nil,
      next_pos: 1,
      session_seq: 0,
      open_session: nil,
      dedup: MapSet.new(),
      dedup_order: :queue.new(),
      buffer: :queue.new(),
      timer: nil,
      idle: nil,
      failed_since: failed_since,
      outage: not is_nil(failed_since),
      retries: 0,
      recover: false,
      read_only: false,
      import_new: false,
      importing: nil,
      import_waiters: [],
      resume: false,
      dropped_span: dropped_span,
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      send_after: Keyword.get(opts, :send_after, &Process.send_after/3),
      run_id: Keyword.get_lazy(opts, :run_id, &Aiur.Boot.run_id/0),
      store: Keyword.get(opts, :store, Aiur.Conversation.Store),
      alerts: Keyword.get(opts, :alerts, Aiur.Alerts),
      pubsub: Keyword.get(opts, :pubsub, Aiur.PubSub)
    }

    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state), do: {:noreply, load(state) |> touch()}

  def handle_continue(:import, state) do
    case JournalImport.step(state, &write_import/2, &publish/3) do
      {:ok, %{importing: nil} = state} ->
        state = flush(state)
        result = if state.outage, do: {:error, :degraded}, else: :ok
        {:noreply, reply_import_waiters(state, result)}

      {:ok, state} ->
        send(self(), :import_step)
        {:noreply, state}

      {:error, reason, state} ->
        state = failure(state, reason) |> reply_import_waiters({:error, :degraded})
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:append, source, entries}, state) do
    state = if is_nil(state.importing), do: JournalImport.start(state, source, entries), else: state
    inputs = Enum.map(entries, &{:entry, source, &1, stamp(state.clock.())})
    state = enqueue(state, inputs)
    if state.importing, do: send(self(), :import_step)
    {:noreply, state}
  end

  def handle_cast({:end_session, provider_id, reason}, state), do: {:noreply, enqueue(state, [{:end_session, provider_id, reason}])}
  def handle_cast({:gap, reason, from, to}, state), do: {:noreply, enqueue(state, [{:gap, reason, stamp(from), stamp(to)}])}

  def handle_cast({:dropped, from, to}, state) do
    state = %{state | dropped_span: span(state.dropped_span, stamp(from), stamp(to))} |> touch()
    {:noreply, schedule(state, 200)}
  end

  @impl true
  def handle_call(:flush, from, %{importing: import} = state) when not is_nil(import) do
    send(self(), :import_step)
    {:noreply, %{state | import_waiters: [from | state.import_waiters]}}
  end

  def handle_call(:flush, _from, state) do
    state = cancel_flush(state) |> flush()
    result = if state.outage, do: {:error, :degraded}, else: :ok
    {:reply, result, state}
  end

  @impl true
  def handle_info(:import_step, %{importing: nil} = state), do: {:noreply, state}

  def handle_info(:import_step, state) do
    case recover(state) do
      {:ok, state} -> {:noreply, state, {:continue, :import}}
      {:error, reason} -> {:noreply, failure(state, reason) |> reply_import_waiters({:error, :degraded})}
    end
  end

  def handle_info({:flush, token}, %{timer: {_timer, token}, importing: import} = state) when not is_nil(import) do
    send(self(), :import_step)
    {:noreply, %{state | timer: nil}}
  end

  def handle_info({:flush, token}, %{timer: {_timer, token}} = state), do: {:noreply, flush(%{state | timer: nil})}
  def handle_info({:flush, _token}, state), do: {:noreply, state}

  def handle_info({:idle, token}, %{idle: {_timer, token}} = state) do
    state = cancel_flush(state) |> flush()
    retain_losses(state)

    {:stop, :normal, state}
  end

  def handle_info({:idle, _token}, state), do: {:noreply, state}

  # Store preparation closes linked command ports; trapping shutdown also delivers their normal exits.
  def handle_info({:EXIT, port, :normal}, state) when is_port(port), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    if reason == :shutdown or match?({:shutdown, _}, reason) do
      state = finish_import(state)
      JournalImport.halt(state)
      state |> flush() |> retain_losses()
    else
      JournalImport.halt(state)
    end

    :ok
  end

  defp finish_import(%{importing: nil} = state), do: state

  defp finish_import(state) do
    with {:ok, state} <- recover(state),
         {:ok, state} <- JournalImport.step(state, &write_import/2, &publish/3) do
      finish_import(state)
    else
      {:error, reason, updated} -> failure(updated, reason)
      {:error, reason} -> failure(state, reason)
    end
  end

  defp retain_losses(state) do
    Ingest.count_dropped(state.id, :queue.len(state.buffer))
    # Preserve detected losses when this writer stops within the same BEAM run.
    if state.failed_since || state.dropped_span,
      do: :persistent_term.put({__MODULE__, state.id, :pending_gaps}, {state.failed_since, state.dropped_span})
  end

  defp load(state) do
    with {:ok, root} <- Paths.conversation_state_dir(),
         state = %{state | dir: Path.join(root, state.id)},
         state = %{state | import_new: not File.exists?(Path.join(state.dir, "head.json")) and Path.wildcard(Path.join(state.dir, "entries.*.jsonl")) == []},
         {:ok, head} <- state.store.prepare(state.dir, state.ref),
         {:ok, loaded} <- JournalSessions.load(state, head) do
      loaded
    else
      {:error, reason} -> failure(state, reason)
    end
  end

  defp enqueue(state, inputs) do
    state = touch(state)

    if state.read_only do
      Ingest.count_dropped(state.id, length(inputs))
      %{state | failed_since: span_inputs(state.failed_since, inputs, state.clock.())}
    else
      state = %{state | buffer: Enum.reduce(inputs, state.buffer, &:queue.in/2)}
      state = if state.outage, do: %{state | failed_since: span_inputs(state.failed_since, inputs, state.clock.())}, else: state
      if :queue.len(state.buffer) >= 50 and not state.outage and is_nil(state.importing), do: cancel_flush(state) |> flush(), else: schedule(state, 200)
    end
  end

  defp flush(%{read_only: true} = state), do: state
  defp flush(%{importing: import} = state) when not is_nil(import), do: state

  defp flush(state) do
    case recover(state) do
      {:ok, state} -> drain(state)
      {:error, reason} -> failure(state, reason)
    end
  end

  defp recover(%{recover: false} = state), do: {:ok, state}

  defp recover(%{dir: nil} = state) do
    state = load(%{state | recover: false})
    if state.recover, do: {:error, :prepare_failed}, else: {:ok, state}
  end

  defp recover(state) do
    with {:ok, head} <- state.store.rebuild_head(state.dir),
         {:ok, state} <- JournalSessions.load(state, head) do
      {:ok, %{state | recover: false}}
    end
  end

  defp drain(state) do
    {inputs, rest} = take(state.buffer)

    {inputs, rest} =
      if match?([{:end_session, _, _}], inputs) and (state.failed_since || state.dropped_span), do: {[], state.buffer}, else: {inputs, rest}

    if inputs == [] and is_nil(state.failed_since) and is_nil(state.dropped_span) do
      recovered(state)
    else
      case write(state, inputs) do
        {:ok, updated, entries, sessions} ->
          publish(updated, entries, sessions)
          updated = recovered(%{updated | buffer: rest, retries: 0, failed_since: nil, dropped_span: nil})
          drain(updated)

        {:error, reason} ->
          failure(state, reason)
      end
    end
  end

  defp reply_import_waiters(state, result) do
    Enum.each(state.import_waiters, &GenServer.reply(&1, result))
    %{state | import_waiters: []}
  end

  defp write_import(state, inputs) do
    with {:ok, updated, entries, sessions} <- write(state, inputs) do
      updated = recovered(%{updated | retries: 0, failed_since: nil, dropped_span: nil})
      {:ok, updated, entries, sessions}
    end
  end

  # A batch stays within one source/session so recovery can dedup a durable prefix.
  defp take(queue) do
    case :queue.out(queue) do
      {:empty, _} -> {[], queue}
      {{:value, {:entry, source, _, _} = input}, rest} -> take_entries(rest, source, [input], 1)
      {{:value, input}, rest} -> {[input], rest}
    end
  end

  defp take_entries(queue, _source, acc, 50), do: {Enum.reverse(acc), queue}

  defp take_entries(queue, source, acc, count) do
    case :queue.out(queue) do
      {{:value, {:entry, ^source, _, _} = input}, rest} -> take_entries(rest, source, [input | acc], count + 1)
      _ -> {Enum.reverse(acc), queue}
    end
  end

  defp write(state, [{:end_session, id, reason}]) do
    if state.open_session && (is_nil(id) or state.open_session.provider_session_id == id) do
      with {:ok, updated, session} <- JournalSessions.close(state, reason), do: {:ok, updated, [], [session]}
    else
      {:ok, state, [], []}
    end
  end

  defp write(state, inputs) do
    with {:ok, state, inputs} <- ProviderReplay.filter(state, inputs),
         {:ok, state, sessions} <- resolve(state, inputs) do
      gaps =
        gap_inputs(state) ++
          Enum.flat_map(inputs, fn
            {:gap, reason, from, to} -> [gap_entry(reason, from, to)]
            _ -> []
          end)

      entries =
        gaps ++
          Enum.flat_map(inputs, fn
            {:entry, _, entry, _} -> [entry]
            _ -> []
          end)

      {entries, updated} = assign(entries, state)

      with {:ok, stat} <- File.stat(Path.join(state.dir, "sessions.jsonl")),
           head = %{state.segment_state | "last_session_seq" => state.session_seq, "sessions_bytes" => stat.size},
           {:ok, head} <- state.store.append_entries(state.dir, head, Enum.map(entries, &Entry.to_json/1)) do
        {:ok, ProviderReplay.remember(%{updated | segment_state: head}, entries), entries, sessions}
      end
    end
  end

  defp resolve(state, [{:entry, source, _, _} | _]), do: JournalSessions.resolve(state, source)
  defp resolve(state, _inputs), do: {:ok, state, []}

  defp gap_inputs(state) do
    outage =
      case state.failed_since do
        nil -> []
        {from, to} -> [gap_entry(:source_unreadable, from, to)]
      end

    dropped =
      case state.dropped_span do
        nil -> []
        {from, to} -> [gap_entry(:backpressure, from, to)]
      end

    outage ++ dropped
  end

  defp gap_entry(reason, from, to), do: %Entry{kind: "gap", role: "system", meta: %{reason: to_string(reason), from: from, to: to}}

  defp assign(entries, state) do
    {entries, state} = Enum.reduce(entries, {[], state}, &assign_entry/2)
    {Enum.reverse(entries), state}
  end

  defp assign_entry(entry, {acc, state}) do
    key = Entry.dedup_key(entry)

    if entry.kind != "gap" and MapSet.member?(state.dedup, key) do
      {acc, state}
    else
      entry = %{entry | pos: state.next_pos, observed_at: state.clock.(), session_seq: if(state.open_session, do: state.open_session.session_seq)}
      session = if state.open_session, do: %{state.open_session | last_pos: entry.pos}
      state = %{state | next_pos: state.next_pos + 1, open_session: session}
      state = if entry.kind == "gap", do: state, else: JournalSessions.remember(state, key)
      {[entry | acc], state}
    end
  end

  defp failure(state, reason) do
    unless state.outage, do: alert(state, "system.conversation.journal.degraded", true, error_class(reason))
    span = span_inputs(state.failed_since, :queue.to_list(state.buffer), state.clock.())
    state = %{state | outage: true, recover: true, failed_since: span, retries: state.retries + 1}

    if corrupt?(reason) do
      Ingest.count_dropped(state.id, :queue.len(state.buffer))
      %{state | read_only: true, buffer: :queue.new()}
    else
      retry(state)
    end
  end

  defp retry(%{retries: retries} = state) when retries > 5 do
    Ingest.count_dropped(state.id, :queue.len(state.buffer))
    %{state | buffer: :queue.new()}
  end

  defp retry(state), do: schedule(state, min(30_000, 1000 * Integer.pow(2, state.retries - 1)))
  defp corrupt?({:corrupt, _, _}), do: true
  defp corrupt?(:invalid_session), do: true
  defp corrupt?(_), do: false
  defp error_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_class(reason) when is_tuple(reason), do: reason |> elem(0) |> error_class()
  defp error_class(_), do: "unknown"

  defp recovered(%{outage: true} = state) do
    :persistent_term.erase({__MODULE__, state.id, :pending_gaps})
    alert(state, "system.conversation.journal.degraded.resolved", false, "recovered")
    %{state | outage: false}
  end

  defp recovered(state) do
    :persistent_term.erase({__MODULE__, state.id, :pending_gaps})
    state
  end

  defp alert(state, name, attention, class) do
    state.alerts.emit_system(name, message: "Conversation #{state.id}: #{class}", needs_attention: attention)
  end

  defp publish(state, entries, sessions) do
    topic = "conversation:" <> state.id
    if entries != [], do: Phoenix.PubSub.broadcast(state.pubsub, topic, {:entries_appended, state.id, entries})
    for session <- sessions, do: Phoenix.PubSub.broadcast(state.pubsub, topic, {:session_changed, state.id, session})
  end

  defp span_inputs(previous, inputs, now) do
    Enum.reduce(inputs, previous || {stamp(now), stamp(now)}, fn
      {:entry, _, _entry, received_at}, span -> span(span, received_at, stamp(now))
      {:gap, _, from, to}, span -> span(span, from, to)
      _, span -> span
    end)
  end

  defp span(nil, from, to), do: {min(from, to), max(from, to)}
  defp span({first, last}, from, to), do: {min(first, min(from, to)), max(last, max(from, to))}
  defp stamp(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp stamp(time), do: time

  defp touch(state) do
    if state.idle, do: Process.cancel_timer(elem(state.idle, 0))
    token = make_ref()
    %{state | idle: {state.send_after.(self(), {:idle, token}, 900_000), token}}
  end

  defp schedule(%{timer: nil} = state, ms) do
    token = make_ref()
    %{state | timer: {state.send_after.(self(), {:flush, token}, ms), token}}
  end

  defp schedule(state, _ms), do: state

  defp cancel_flush(state) do
    if state.timer, do: Process.cancel_timer(elem(state.timer, 0))
    %{state | timer: nil}
  end
end
