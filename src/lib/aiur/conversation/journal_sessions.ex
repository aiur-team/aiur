defmodule Aiur.Conversation.JournalSessions do
  @moduledoc false
  alias Aiur.Conversation.{Entry, Session, Store}

  @spec load(map(), map()) :: {:ok, map()} | {:error, term()}
  def load(state, head) do
    with {:ok, bytes} <- File.read(Path.join(state.dir, "sessions.jsonl")),
         lines = String.split(bytes, "\n", trim: true),
         {:ok, session} <- replay(lines),
         from = if(session, do: session.first_pos, else: head["last_pos"] + 1),
         from = if(state.recover, do: min(from, state.next_pos), else: from),
         {:ok, entries} <- state.store.stream_entries(state.dir, from, :infinity) do
      entries = Enum.to_list(entries)
      if state.recover, do: publish_recovered(state, bytes, entries)
      state = if state.recover, do: reconcile_gaps(state, entries), else: state
      session = if session, do: %{session | last_pos: last_pos(entries, session.session_seq)}, else: nil
      state = %{state | segment_state: head, next_pos: head["last_pos"] + 1, session_seq: head["last_session_seq"], open_session: session, dedup: MapSet.new(), dedup_order: :queue.new()}
      state = Map.delete(state, :provider_replay)
      state = Enum.reduce(entries, state, &recover_entry/2)
      state = %{state | resume: state.resume or (is_nil(session) and restart_resume?(List.last(lines)))}
      restart(state)
    end
  end

  defp restart_resume?(nil), do: false

  defp restart_resume?(line) do
    {:ok, session} = Session.from_json(line)
    session.end_reason == "daemon_restart_unknown"
  end

  defp publish_recovered(state, bytes, entries) do
    entries =
      Enum.filter(entries, &(&1["pos"] >= state.next_pos))
      |> Enum.map(fn entry ->
        {:ok, entry} = Entry.from_json(entry)
        entry
      end)

    if entries != [], do: Phoenix.PubSub.broadcast(state.pubsub, "conversation:" <> state.id, {:entries_appended, state.id, entries})
    offset = if state.segment_state, do: state.segment_state["sessions_bytes"], else: 0

    bytes
    |> binary_part(offset, byte_size(bytes) - offset)
    |> String.split("\n", trim: true)
    |> Enum.each(fn line ->
      {:ok, session} = Session.from_json(line)
      session = if session.end_reason && state.open_session, do: %{state.open_session | ended_at: session.ended_at, end_reason: session.end_reason, last_pos: session.last_pos}, else: session
      Phoenix.PubSub.broadcast(state.pubsub, "conversation:" <> state.id, {:session_changed, state.id, session})
    end)
  end

  defp replay(lines) do
    Enum.reduce_while(lines, {:ok, nil}, fn line, {:ok, open} ->
      case Session.from_json(line) do
        {:ok, %{end_reason: nil} = session} -> {:cont, {:ok, session}}
        {:ok, session} when not is_nil(open) and session.session_seq == open.session_seq -> {:cont, {:ok, nil}}
        {:ok, _session} -> {:cont, {:ok, open}}
        error -> {:halt, error}
      end
    end)
  end

  defp last_pos(entries, seq) do
    entries
    |> Enum.filter(&(&1["session_seq"] == seq))
    |> List.last()
    |> case do
      nil -> nil
      entry -> entry["pos"]
    end
  end

  defp recover_entry(entry, state) do
    state = if (entry["kind"] != "gap" and state.open_session) && entry["session_seq"] == state.open_session.session_seq, do: remember(state, Entry.dedup_key(entry)), else: state
    if gap_matches?(entry, state.failed_since), do: %{state | failed_since: nil}, else: state
  end

  defp reconcile_gaps(state, entries) do
    gaps = entries |> Enum.filter(&(&1["pos"] >= state.next_pos and &1["kind"] == "gap")) |> Enum.map(& &1["meta"]) |> MapSet.new()

    dropped_span =
      case state.dropped_span do
        nil -> nil
        {from, to} = span -> if MapSet.member?(gaps, %{"reason" => "backpressure", "from" => from, "to" => to}), do: nil, else: span
      end

    buffer =
      state.buffer
      |> :queue.to_list()
      |> Enum.reject(fn
        {:gap, reason, from, to} -> MapSet.member?(gaps, %{"reason" => to_string(reason), "from" => from, "to" => to})
        _ -> false
      end)
      |> :queue.from_list()

    %{state | dropped_span: dropped_span, buffer: buffer}
  end

  defp gap_matches?(%{"kind" => "gap", "meta" => meta}, {from, to}),
    do: meta["reason"] == "source_unreadable" and meta["from"] == from and meta["to"] == to

  defp gap_matches?(_, _), do: false

  defp restart(%{open_session: %Session{start_reason: "import"}} = state), do: {:ok, state}

  defp restart(%{open_session: %Session{} = session} = state) do
    if session.aiur_run_id == state.run_id do
      {:ok, state}
    else
      with {:ok, state, ended} <- close(state, "daemon_restart_unknown") do
        Phoenix.PubSub.broadcast(state.pubsub, "conversation:" <> state.id, {:session_changed, state.id, ended})
        {:ok, %{state | resume: true}}
      end
    end
  end

  defp restart(state), do: {:ok, state}

  @spec resolve(map(), map()) :: {:ok, map(), [Session.t()]} | {:error, term()}
  def resolve(state, source) do
    session = state.open_session
    key = {source.harness, source.provider_session_id}

    cond do
      session && {session.harness, session.provider_session_id} == key ->
        {:ok, state, []}

      session ->
        with {:ok, state, ended} <- close(state, "superseded"),
             {:ok, state, opened} <- open(state, source) do
          {:ok, state, [ended, opened]}
        end

      true ->
        with {:ok, state, opened} <- open(state, source), do: {:ok, state, [opened]}
    end
  end

  defp open(state, source) do
    session = %Session{
      session_seq: state.session_seq + 1,
      harness: source.harness,
      provider_session_id: source.provider_session_id,
      aiur_attempt_id: Map.get(source, :aiur_attempt_id),
      aiur_run_id: state.run_id,
      first_pos: state.next_pos,
      started_at: state.clock.(),
      start_reason: if(state.resume and source.start_reason != :import, do: "resume", else: to_string(source.start_reason)),
      transcript_source: Map.get(source, :transcript_source),
      meta: Map.get(source, :meta, %{})
    }

    with :ok <- state.store.append_session_line(state.dir, Session.start_line(session)) do
      {:ok, %{state | open_session: session, session_seq: session.session_seq, resume: false, dedup: MapSet.new(), dedup_order: :queue.new()}, session}
    end
  end

  @spec close(map(), atom() | String.t()) :: {:ok, map(), Session.t() | nil} | {:error, term()}
  def close(%{open_session: nil} = state, _reason), do: {:ok, state, nil}

  def close(state, reason) do
    session = %{state.open_session | ended_at: state.clock.(), end_reason: to_string(reason)}

    with :ok <- state.store.append_session_line(state.dir, Session.end_line(session, %{})),
         {:ok, stat} <- File.stat(Path.join(state.dir, "sessions.jsonl")),
         head = %{state.segment_state | "sessions_bytes" => stat.size},
         :ok <- Store.write_head(state.dir, head) do
      {:ok, %{state | segment_state: head, open_session: nil, dedup: MapSet.new(), dedup_order: :queue.new()}, session}
    end
  end

  @spec remember(map(), String.t()) :: map()
  def remember(state, key) do
    if MapSet.member?(state.dedup, key) do
      state
    else
      state = %{state | dedup: MapSet.put(state.dedup, key), dedup_order: :queue.in(key, state.dedup_order)}

      if MapSet.size(state.dedup) > 50_000 do
        {{:value, oldest}, order} = :queue.out(state.dedup_order)
        %{state | dedup: MapSet.delete(state.dedup, oldest), dedup_order: order}
      else
        state
      end
    end
  end
end
