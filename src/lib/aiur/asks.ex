defmodule Aiur.Asks do
  @moduledoc """
  Durable Executor-authored requests for the repository operator.

  Ask records are append-only: creating an ask writes its complete request and
  resolving it appends a terminal event. Reading reduces that history to the
  current state, so a completed request remains auditable without rewriting the
  original request.
  """

  alias Aiur.Asks.Store

  @urgencies ~w(low normal high)
  @id_prefix "ask_"

  @type ask :: %{required(String.t()) => term()}

  @spec create(String.t(), map()) :: {:ok, ask()} | {:error, term()}
  def create(repo, attrs) when is_binary(repo) and is_map(attrs) do
    ask = %{
      "id" => new_id(),
      "title" => Map.get(attrs, :title),
      "body" => Map.get(attrs, :body),
      "urgency" => Map.get(attrs, :urgency, "normal"),
      "blocking" => Map.get(attrs, :blocking, false),
      "status" => "open",
      "created_at" => now(),
      "created_by" => "executor"
    }

    with :ok <- validate_open(ask),
         :ok <- Store.with_lock(repo, fn -> Store.append(repo, ask) end) do
      {:ok, ask}
    end
  end

  @spec resolve(String.t(), String.t(), String.t() | nil) :: {:ok, ask()} | {:error, term()}
  def resolve(repo, id, note \\ nil) when is_binary(repo) and is_binary(id) do
    with :ok <- validate_id(id),
         :ok <- validate_optional_body(note),
         {:ok, ask} <-
           Store.with_lock(repo, fn ->
             with {:ok, asks} <- all_unlocked(repo),
                  {:ok, open_ask} <- find_open(asks, id),
                  resolution <- %{
                    "id" => id,
                    "status" => "done",
                    "resolved_at" => now(),
                    "resolved_by" => "executor",
                    "note" => note
                  },
                  :ok <- validate_done(resolution),
                  :ok <- Store.append(repo, resolution) do
               {:ok, Map.merge(open_ask, resolution)}
             end
           end) do
      {:ok, ask}
    end
  end

  @spec all(String.t()) :: {:ok, [ask()]} | {:error, term()}
  def all(repo) when is_binary(repo), do: Store.with_lock(repo, fn -> all_unlocked(repo) end)

  @spec open(String.t()) :: {:ok, [ask()]} | {:error, term()}
  def open(repo) when is_binary(repo) do
    with {:ok, asks} <- all(repo), do: {:ok, Enum.filter(asks, &(&1["status"] == "open"))}
  end

  defp all_unlocked(repo) do
    with {:ok, events} <- Store.events(repo),
         {:ok, asks} <- reduce_events(events) do
      {:ok, asks |> Map.values() |> Enum.sort_by(& &1["created_at"], :desc)}
    end
  end

  @doc false
  @spec validate_events([map()]) :: :ok | {:error, {pos_integer(), term()}}
  def validate_events(events) when is_list(events) do
    tagged = events |> Enum.with_index(1) |> Enum.map(fn {event, line_number} -> {event, line_number, nil} end)

    case reduce_events(tagged) do
      {:ok, _asks} -> :ok
      {:error, {:invalid_ask_record, nil, line_number, reason}} -> {:error, {line_number, reason}}
    end
  end

  defp reduce_events(events) do
    Enum.reduce_while(events, {:ok, %{}}, fn {event, line_number, path}, {:ok, asks} ->
      with :ok <- validate_event(event),
           {:ok, updated} <- reduce_event(event, asks) do
        {:cont, {:ok, updated}}
      else
        {:error, reason} -> {:halt, {:error, {:invalid_ask_record, path, line_number, reason}}}
      end
    end)
  end

  defp reduce_event(%{"status" => "open", "id" => id} = ask, asks) do
    if Map.has_key?(asks, id), do: {:error, {:invalid_ask_transition, :duplicate_open}}, else: {:ok, Map.put(asks, id, ask)}
  end

  defp reduce_event(%{"status" => "done", "id" => id} = resolution, asks) do
    case Map.get(asks, id) do
      nil -> {:error, {:invalid_ask_transition, :orphan_done}}
      %{"status" => "done"} -> {:error, {:invalid_ask_transition, :duplicate_done}}
      ask -> {:ok, Map.put(asks, id, Map.merge(ask, resolution))}
    end
  end

  defp find_open(asks, id) do
    case Enum.find(asks, &(&1["id"] == id)) do
      nil -> {:error, {:ask_not_found, id}}
      %{"status" => "done"} -> {:error, {:ask_already_done, id}}
      ask -> {:ok, ask}
    end
  end

  defp validate_event(%{"status" => "open"} = ask), do: validate_open(ask)
  defp validate_event(%{"status" => "done"} = ask), do: validate_done(ask)
  defp validate_event(_ask), do: {:error, {:invalid_ask, :status}}

  defp validate_open(ask) do
    with :ok <- validate_id(ask["id"]),
         :ok <- required_string(ask, "title"),
         :ok <- validate_optional_body(ask["body"]),
         :ok <- validate_urgency(ask["urgency"]),
         :ok <- validate_boolean(ask["blocking"], "blocking"),
         :ok <- required_timestamp(ask, "created_at"),
         :ok <- required_string(ask, "created_by"),
         do: :ok
  end

  defp validate_done(ask) do
    with :ok <- validate_id(ask["id"]),
         :ok <- required_timestamp(ask, "resolved_at"),
         :ok <- required_string(ask, "resolved_by"),
         :ok <- validate_optional_body(ask["note"]),
         do: :ok
  end

  defp required_timestamp(ask, key) do
    with :ok <- required_string(ask, key),
         {:ok, _timestamp, _offset} <- DateTime.from_iso8601(ask[key]) do
      :ok
    else
      _ -> {:error, {:invalid_ask, key}}
    end
  end

  defp required_string(ask, key) do
    case Map.get(ask, key) do
      value when is_binary(value) -> if(String.trim(value) == "", do: {:error, {:invalid_ask, key}}, else: :ok)
      _ -> {:error, {:invalid_ask, key}}
    end
  end

  defp validate_id(id) when is_binary(id), do: if(String.match?(id, ~r/\Aask_[A-Za-z0-9_-]+\z/), do: :ok, else: {:error, {:invalid_ask, :id}})
  defp validate_id(_id), do: {:error, {:invalid_ask, :id}}
  defp validate_optional_body(nil), do: :ok
  defp validate_optional_body(body) when is_binary(body), do: :ok
  defp validate_optional_body(_body), do: {:error, {:invalid_ask, :body_or_note}}
  defp validate_urgency(urgency) when urgency in @urgencies, do: :ok
  defp validate_urgency(_urgency), do: {:error, {:invalid_ask, :urgency}}
  defp validate_boolean(value, _key) when is_boolean(value), do: :ok
  defp validate_boolean(_value, key), do: {:error, {:invalid_ask, key}}
  defp new_id, do: @id_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
