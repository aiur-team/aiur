defmodule Aiur.Asks do
  @moduledoc """
  Durable Executor-authored requests for the repository operator.

  Ask records are append-only: creating an ask writes its complete request and
  resolving it appends a terminal event. Reading reduces that history to the
  current state, so a completed request remains auditable without rewriting the
  original request.
  """

  alias Aiur.RepoBase

  @max_record_bytes 16 * 1024
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
         :ok <- append(repo, ask) do
      {:ok, ask}
    end
  end

  @spec resolve(String.t(), String.t(), String.t() | nil) :: {:ok, ask()} | {:error, term()}
  def resolve(repo, id, note \\ nil) when is_binary(repo) and is_binary(id) do
    with :ok <- validate_id(id),
         :ok <- validate_optional_body(note),
         {:ok, asks} <- all(repo),
         {:ok, ask} <- find_open(asks, id),
         resolution <- %{"id" => id, "status" => "done", "resolved_at" => now(), "resolved_by" => "executor", "note" => note},
         :ok <- validate_done(resolution),
         :ok <- append(repo, resolution) do
      {:ok, Map.merge(ask, resolution)}
    end
  end

  @spec all(String.t()) :: {:ok, [ask()]} | {:error, term()}
  def all(repo) when is_binary(repo) do
    with :ok <- RepoBase.ensure_state_tree(repo),
         {:ok, events} <- read_events(RepoBase.asks_path(repo)) do
      {:ok,
       events
       |> Enum.reduce(%{}, &reduce_event/2)
       |> Map.values()
       |> Enum.sort_by(& &1["created_at"], :desc)}
    end
  end

  @spec open(String.t()) :: {:ok, [ask()]} | {:error, term()}
  def open(repo) when is_binary(repo) do
    with {:ok, asks} <- all(repo) do
      {:ok, Enum.filter(asks, &(&1["status"] == "open"))}
    end
  end

  defp append(repo, ask) do
    with {:ok, encoded} <- Jason.encode(ask),
         :ok <- validate_size(encoded <> "\n"),
         :ok <- RepoBase.ensure_state_tree(repo) do
      append_line(RepoBase.asks_path(repo), encoded <> "\n")
    end
  end

  defp append_line(path, line) do
    case File.open(path, [:append, :binary]) do
      {:ok, device} ->
        try do
          IO.binwrite(device, line)
        after
          File.close(device)
        end

      {:error, reason} ->
        {:error, {:ask_append_open_failed, path, reason}}
    end
  end

  defp read_events(path) do
    case File.read(path) do
      {:ok, contents} -> decode_events(contents, path)
      {:error, reason} -> {:error, {:ask_read_failed, path, reason}}
    end
  end

  defp decode_events(contents, path) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, line_number}, {:ok, events} ->
      case Jason.decode(line) do
        {:ok, event} when is_map(event) ->
          case validate_event(event) do
            :ok -> {:cont, {:ok, [event | events]}}
            {:error, reason} -> {:halt, {:error, {:invalid_ask_record, path, line_number, reason}}}
          end

        _ ->
          {:halt, {:error, {:invalid_ask_record, path, line_number, "invalid JSON"}}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  defp reduce_event(%{"status" => "open", "id" => id} = ask, state), do: Map.put(state, id, ask)

  defp reduce_event(%{"status" => "done", "id" => id} = resolution, state) do
    Map.update(state, id, resolution, &Map.merge(&1, resolution))
  end

  defp find_open(asks, id) do
    case Enum.find(asks, &(&1["id"] == id)) do
      nil -> {:error, "ask #{id} was not found"}
      %{"status" => "done"} -> {:error, "ask #{id} is already done"}
      ask -> {:ok, ask}
    end
  end

  defp validate_event(%{"status" => "open"} = ask), do: validate_open(ask)
  defp validate_event(%{"status" => "done"} = ask), do: validate_done(ask)
  defp validate_event(_ask), do: {:error, "ask status must be open or done"}

  defp validate_open(ask) do
    with :ok <- validate_id(ask["id"]),
         :ok <- required_string(ask, "title"),
         :ok <- validate_optional_body(ask["body"]),
         :ok <- validate_urgency(ask["urgency"]),
         :ok <- validate_boolean(ask["blocking"], "blocking"),
         :ok <- required_timestamp(ask, "created_at"),
         :ok <- required_string(ask, "created_by") do
      :ok
    end
  end

  defp validate_done(ask) do
    with :ok <- validate_id(ask["id"]),
         :ok <- required_timestamp(ask, "resolved_at"),
         :ok <- required_string(ask, "resolved_by"),
         :ok <- validate_optional_body(ask["note"]) do
      :ok
    end
  end

  defp required_timestamp(ask, key) do
    with :ok <- required_string(ask, key),
         {:ok, _timestamp, _offset} <- DateTime.from_iso8601(ask[key]) do
      :ok
    else
      _ -> {:error, "ask requires an ISO-8601 #{key}"}
    end
  end

  defp required_string(ask, key) do
    case Map.get(ask, key) do
      value when is_binary(value) -> if(String.trim(value) == "", do: {:error, "ask requires non-empty #{key}"}, else: :ok)
      _ -> {:error, "ask requires non-empty #{key}"}
    end
  end

  defp validate_id(id) when is_binary(id) do
    if String.match?(id, ~r/\Aask_[A-Za-z0-9_-]+\z/), do: :ok, else: {:error, "ask id is invalid"}
  end

  defp validate_id(_id), do: {:error, "ask id is invalid"}

  defp validate_optional_body(nil), do: :ok
  defp validate_optional_body(body) when is_binary(body), do: :ok
  defp validate_optional_body(_body), do: {:error, "ask body and note must be text"}

  defp validate_urgency(urgency) when urgency in @urgencies, do: :ok
  defp validate_urgency(_urgency), do: {:error, "ask urgency must be one of: #{Enum.join(@urgencies, ", ")}"}

  defp validate_boolean(value, _key) when is_boolean(value), do: :ok
  defp validate_boolean(_value, key), do: {:error, "ask #{key} must be true or false"}

  defp validate_size(line) when byte_size(line) <= @max_record_bytes, do: :ok

  defp validate_size(line),
    do: {:error, "ask exceeds the #{@max_record_bytes}-byte atomic append limit (got #{byte_size(line)} bytes)"}

  defp new_id do
    @id_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
