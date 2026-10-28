defmodule Aiur.Conversation.Ingest do
  @moduledoc "Best-effort, nonblocking producer boundary for the durable conversation journal."
  require Logger
  alias Aiur.Conversation.{Entry, Journal, Ref}

  @type source :: %{
          harness: String.t(),
          role: :worker | :executor,
          provider_session_id: String.t() | nil,
          aiur_attempt_id: String.t() | nil,
          transcript_source: %{kind: atom(), locator_hash: String.t() | nil},
          start_reason: atom()
        }

  @spec append(Ref.t(), source(), [map()]) :: :ok
  def append(ref, source, events) do
    safe(ref, fn ->
      entries = Enum.flat_map(events, &convert(&1, source.role))

      if entries != [], do: dispatch(ref, {:append, source, entries}, length(entries))
    end)
  end

  @spec end_session(Ref.t(), String.t() | nil, atom() | String.t()) :: :ok
  def end_session(ref, provider_id, reason), do: safe(ref, fn -> dispatch(ref, {:end_session, provider_id, reason}, 0) end)

  @spec gap(Ref.t(), atom() | String.t(), DateTime.t(), DateTime.t()) :: :ok
  def gap(ref, reason, from, to), do: safe(ref, fn -> dispatch(ref, {:gap, reason, from, to}, 0) end)

  @spec anchor(Ref.t(), map()) :: :ok
  def anchor(ref, anchor), do: safe(ref, fn -> dispatch(ref, {:anchor, anchor}, 0) end)

  @spec writer(Ref.t()) :: {:ok, pid()} | {:error, term()}
  def writer(ref) do
    case Registry.lookup(Aiur.Conversation.Registry, Ref.conversation_id(ref)) do
      [{pid, _}] -> if Process.alive?(pid), do: {:ok, pid}, else: start_writer(ref)
      [] -> start_writer(ref)
    end
  end

  defp start_writer(ref) do
    case DynamicSupervisor.start_child(Aiur.Conversation.JournalSupervisor, {Journal, ref}) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      result -> result
    end
  end

  @spec dropped_count(Ref.t()) :: non_neg_integer()
  def dropped_count(ref), do: :counters.get(counter(Ref.conversation_id(ref)), 1)

  @doc false
  @spec count_dropped(String.t(), non_neg_integer()) :: :ok
  def count_dropped(_id, 0), do: :ok
  def count_dropped(id, count), do: :counters.add(counter(id), 1, count)

  defp convert(event, role) do
    case Entry.from_transcript_event(event, subject_kind: role) do
      {:ok, entry} -> [entry]
      :skip -> []
    end
  end

  defp create_counter(key) do
    case :persistent_term.get(key, nil) do
      nil ->
        counter = :counters.new(1, [:write_concurrency])
        :persistent_term.put(key, counter)
        counter

      counter ->
        counter
    end
  end

  defp counter(id) do
    key = {__MODULE__, :dropped, id}

    case :persistent_term.get(key, nil) do
      nil ->
        :global.trans({key, self()}, fn -> create_counter(key) end)

      counter ->
        counter
    end
  end

  defp dispatch(ref, message, count) do
    case writer(ref) do
      {:ok, pid} -> dispatch_to(pid, ref, message, count)
      {:error, _reason} -> Logger.warning("Conversation #{safe_id(ref)}: journal start_failed")
    end
  end

  defp dispatch_to(pid, ref, message, count) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, size} when size > 5000 and count > 0 ->
        count_dropped(Ref.conversation_id(ref), count)
        now = DateTime.utc_now()
        GenServer.cast(pid, {:dropped, now, now})

      nil ->
        Logger.warning("Conversation #{safe_id(ref)}: journal unavailable")

      _ ->
        GenServer.cast(pid, message)
    end
  end

  defp safe_id(ref) do
    Ref.conversation_id(ref)
  catch
    _, _ -> "unknown"
  end

  defp safe(ref, fun) do
    try do
      fun.()
    catch
      kind, _reason -> Logger.warning("Conversation #{safe_id(ref)}: ingest failed (#{kind})")
    end

    :ok
  end
end
