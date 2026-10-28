defmodule Aiur.Conversation.JournalImport do
  @moduledoc false
  alias Aiur.Conversation.{Entry, Importer, JournalSessions}

  @spec eligible?(map()) :: boolean()
  def eligible?(state) do
    cond do
      state.open_session && state.open_session.start_reason == "import" -> true
      state.segment_state["last_pos"] == 1 and state.session_seq == 0 -> gap_only?(state)
      true -> state.import_new
    end
  end

  defp gap_only?(state) do
    case state.store.stream_entries(state.dir, 1, 1) do
      {:ok, entries} -> Enum.any?(entries, &(&1["kind"] == "gap" and &1["meta"]["reason"] == "pre_journal"))
      _ -> false
    end
  end

  @spec start(map(), map(), list()) :: map()
  def start(state, source, entries) do
    hint = Map.get(source, :import_hint)

    if source.role == :worker and is_map(hint) and eligible?(state) do
      plan = Importer.plan(hint)

      import = %{
        hint: hint,
        plan: plan,
        cursor: cursor(plan, hint.backend),
        pending: nil,
        skipped: 0,
        seen: not is_nil(state.open_session),
        resume_line: resume_line(state, plan),
        exclude: MapSet.new(entries, &Entry.dedup_key/1),
        live: entries,
        source: %{source | provider_session_id: "pre_journal", start_reason: :import, transcript_source: %{kind: :provider_file, locator_hash: nil}},
        gap: state.next_pos == 1,
        to: List.first(entries).occurred_at || DateTime.to_iso8601(state.clock.())
      }

      %{state | importing: import, import_new: false}
    else
      %{state | import_new: false}
    end
  end

  @spec start_buffered(map()) :: map()
  def start_buffered(%{read_only: true} = state), do: state

  def start_buffered(%{importing: nil} = state) do
    case state.buffer |> :queue.to_list() |> Enum.find(&match?({:entry, _, _, _}, &1)) do
      {:entry, source, entry, _received_at} -> start(state, source, [entry])
      _ -> state
    end
  end

  def start_buffered(state), do: state

  @spec step(map(), function(), function()) :: {:ok, map()} | {:error, term(), map()}
  def step(%{next_pos: pos, importing: %{gap: true} = import} = state, _write, _publish) when pos > 1,
    do: {:ok, %{state | importing: %{import | gap: false}}}

  def step(%{importing: %{gap: true} = import} = state, write, publish) do
    case write.(state, [{:gap, :pre_journal, nil, import.to}]) do
      {:ok, state, entries, sessions} ->
        publish.(state, entries, sessions)
        {:ok, %{state | importing: %{import | gap: false}}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  def step(state, write, publish) do
    import = state.importing
    {batch, cursor} = import.pending || pull(import.cursor)
    import = %{import | pending: {batch, cursor}}
    state = %{state | importing: import}

    if batch == :done do
      finish(state, publish)
    else
      append_batch(state, batch, cursor, write, publish)
    end
  end

  defp append_batch(state, batch, cursor, write, publish) do
    import = state.importing

    {batch, boundary} =
      Enum.split_while(batch, fn
        {:entry, entry} -> not live_entry?(entry, import)
        _ -> true
      end)

    cursor = if boundary == [], do: cursor, else: stop_at_live(cursor)

    skipped =
      Enum.reduce(batch, import.skipped, fn
        {:skipped, n}, acc -> acc + n
        _, acc -> acc
      end)

    entries = for {:entry, entry} <- batch, entry.meta.import_line > import.resume_line, not MapSet.member?(import.exclude, Entry.dedup_key(entry)), do: entry
    inputs = Enum.map(entries, &{:entry, import.source, &1, import.to})

    case write_batches(state, inputs, write, publish) do
      {:ok, updated} ->
        import = %{import | cursor: cursor, pending: nil, skipped: skipped, seen: import.seen or entries != []}
        {:ok, %{updated | importing: import}}

      error ->
        error
    end
  end

  defp write_batches(state, inputs, write, publish) do
    inputs
    |> Enum.chunk_every(50)
    |> Enum.reduce_while({:ok, state}, fn batch, {:ok, state} ->
      case write.(state, batch) do
        {:ok, updated, written, sessions} ->
          publish.(updated, written, sessions)
          {:cont, {:ok, updated}}

        {:error, reason} ->
          {:halt, {:error, reason, state}}
      end
    end)
  end

  defp finish(%{importing: %{plan: {:workspace, _}, seen: false} = import} = state, _publish) do
    plan = Importer.fallback(import.hint)
    {:ok, %{state | importing: %{import | plan: plan, cursor: cursor(plan, import.hint.backend), pending: nil}}}
  end

  defp finish(state, publish) do
    import = state.importing

    state =
      if state.open_session && state.open_session.start_reason == "import",
        do: %{state | open_session: %{state.open_session | meta: %{skipped_lines: import.skipped}}},
        else: state

    case JournalSessions.close(state, "superseded") do
      {:ok, updated, session} ->
        if session, do: publish.(updated, [], [session])
        {:ok, %{updated | importing: nil}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @spec halt(map()) :: :ok
  def halt(%{importing: %{cursor: cursor}}) when is_function(cursor),
    do:
      (
        cursor.({:halt, nil})
        :ok
      )

  def halt(_state), do: :ok

  defp resume_line(%{open_session: %{start_reason: "import", first_pos: first, last_pos: pos}} = state, {kind, _path}) when is_integer(pos) do
    case state.store.stream_entries(state.dir, first, pos) do
      {:ok, entries} ->
        Enum.reduce(entries, 0, fn entry, line ->
          resume_entry(entry, line, to_string(kind))
        end)

      _ ->
        0
    end
  end

  defp resume_line(_state, _plan), do: 0

  defp resume_entry(entry, line, kind) do
    if entry["meta"]["import_source"] == kind, do: max(line, entry["meta"]["import_line"] || 0), else: line
  end

  defp live_entry?(entry, import) do
    MapSet.member?(import.exclude, Entry.dedup_key(entry)) or
      (entry.meta.import_source == "issue_log" and Enum.any?(import.live, &same_issue_record?(entry, &1)))
  end

  defp same_issue_record?(entry, live) do
    body_matches = entry.body == live.body or (entry.body_truncated and String.starts_with?(live.body, String.slice(entry.body, 0, 1000)))

    entry.kind == live.kind and entry.role == live.role and entry.occurred_at == live.occurred_at and
      Map.get(entry.refs, :provider_msg_id) == Map.get(live.refs, :provider_msg_id) and body_matches
  end

  defp stop_at_live(cursor) do
    cursor.({:halt, nil})
    fn _command -> {:done, nil} end
  end

  defp cursor(plan, backend) do
    stream = plan |> Importer.stream(backend) |> Stream.chunk_every(500)
    fn command -> Enumerable.reduce(stream, command, fn batch, _ -> {:suspend, batch} end) end
  end

  defp pull(cursor) do
    case cursor.({:cont, nil}) do
      {:suspended, batch, next} -> {batch, next}
      {:done, _} -> {:done, cursor}
      {:halted, _} -> {:done, cursor}
    end
  end
end
