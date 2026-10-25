defmodule VoiceConverse.TranscriptIndex do
  @moduledoc "Derived index and read API for append-only voice transcripts."

  alias VoiceConverse.TranscriptIndex.{IndexFile, Reconciler, Transcripts}

  @spec reconcile(Path.t(), keyword()) :: {:ok, %{reconciled: non_neg_integer(), errors: [term()]}} | {:error, term()}
  def reconcile(root, opts \\ []), do: Reconciler.reconcile(root, opts)

  @spec record_opened(Path.t(), String.t()) :: :ok | {:error, term()}
  def record_opened(root, conversation_id), do: record_event(root, conversation_id, "opened")

  @spec record_closed(Path.t(), String.t()) :: :ok | {:error, term()}
  def record_closed(root, conversation_id), do: record_event(root, conversation_id, "closed")

  @spec list(Path.t(), keyword()) :: {:ok, [map()], String.t() | nil} | {:error, term()}
  def list(root, opts \\ []) do
    with {:ok, limit} <- limit(opts, 100),
         {:ok, conversations} <- IndexFile.read_or_rebuild(root),
         {:ok, conversations} <- filter(conversations, Keyword.get(opts, :filter, %{})),
         {:ok, page, cursor} <- page(conversations, Keyword.get(opts, :before), limit) do
      {:ok, page, cursor}
    end
  end

  @spec get(Path.t(), String.t(), keyword()) :: {:ok, [map()], non_neg_integer() | nil} | {:error, term()}
  def get(root, conversation_id, opts \\ []) do
    with {:ok, limit} <- limit(opts, 500),
         {:ok, after_seq} <- cursor(Keyword.get(opts, :after)),
         {:ok, records, next_cursor} <- Transcripts.records_after(root, conversation_id, after_seq, limit) do
      {:ok, records, next_cursor}
    end
  end

  @spec minutes_today(Path.t(), keyword()) :: non_neg_integer() | {:error, term()}
  def minutes_today(root, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    local_date = Keyword.get(opts, :local_date, &local_date/1)
    today = Keyword.get_lazy(opts, :today, fn -> local_date.(now) end)

    closed =
      case IndexFile.read_or_rebuild(root) do
        {:ok, conversations} ->
          conversations
          |> Enum.filter(&(is_integer(&1.duration_s) and starts_on?(&1, today, local_date)))
          |> Enum.map(& &1.duration_s)
          |> Enum.sum()

        {:error, reason} ->
          {:error, reason}
      end

    open =
      Keyword.get(opts, :open_sessions, fn -> [] end).()
      |> Enum.reduce(0, fn session, total ->
        with {:ok, started_at} <- session_started_at(session), true <- local_date.(started_at) == today do
          total + max(DateTime.diff(now, started_at), 0)
        else
          _ -> total
        end
      end)

    if is_integer(closed), do: ceil_minutes(closed + open), else: closed
  end

  defp record_event(root, conversation_id, op) do
    with {:ok, conversation} <- Transcripts.conversation(root, conversation_id),
         do: IndexFile.append(root, op, conversation)
  end

  defp filter(conversations, filter) when is_map(filter) do
    target = Map.get(filter, :target, Map.get(filter, "target"))

    with {:ok, since} <- since(Map.get(filter, :since, Map.get(filter, "since"))) do
      {:ok,
       Enum.filter(
         conversations,
         &((is_nil(target) or &1.target == target) and (is_nil(since) or after_or_equal?(&1.started_at, since)))
       )}
    end
  end

  defp filter(_, _), do: {:error, :invalid_filter}
  defp page(conversations, nil, limit), do: make_page(conversations, limit)

  defp page(conversations, before, limit) when is_binary(before) do
    case Enum.split_while(conversations, &(&1.conversation_id != before)) do
      {_, []} -> {:error, :invalid_cursor}
      {_, [_ | remaining]} -> make_page(remaining, limit)
    end
  end

  defp page(_, _, _), do: {:error, :invalid_cursor}

  defp make_page(conversations, limit) do
    entries = Enum.take(conversations, limit)
    cursor = if length(conversations) > limit, do: List.last(entries).conversation_id, else: nil
    {:ok, entries, cursor}
  end

  defp limit(opts, maximum) do
    case Keyword.get(opts, :limit, maximum) do
      value when is_integer(value) and value in 1..maximum//1 -> {:ok, value}
      _ -> {:error, :invalid_limit}
    end
  end

  defp cursor(nil), do: {:ok, 0}
  defp cursor(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp cursor(_), do: {:error, :invalid_cursor}
  defp since(nil), do: {:ok, nil}
  defp since(%DateTime{} = value), do: {:ok, value}
  defp since(value) when is_binary(value), do: parse_time(value)
  defp since(_), do: {:error, :invalid_since}

  defp after_or_equal?(started_at, since) do
    case parse_time(started_at) do
      {:ok, value} -> DateTime.compare(value, since) != :lt
      {:error, _} -> false
    end
  end

  defp starts_on?(conversation, today, local_date) do
    case parse_time(conversation.started_at) do
      {:ok, value} -> local_date.(value) == today
      {:error, _} -> false
    end
  end

  defp session_started_at(%{started_at: %DateTime{} = value}), do: {:ok, value}
  defp session_started_at(%{"started_at" => %DateTime{} = value}), do: {:ok, value}
  defp session_started_at(_), do: {:error, :invalid_session}

  defp local_date(datetime) do
    datetime
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> then(fn {date, _} -> Date.from_erl!(date) end)
  end

  defp ceil_minutes(0), do: 0
  defp ceil_minutes(seconds), do: div(seconds + 59, 60)

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, value, _} -> {:ok, value}
      _ -> {:error, :invalid_time}
    end
  end

  defp parse_time(_), do: {:error, :invalid_time}
end
