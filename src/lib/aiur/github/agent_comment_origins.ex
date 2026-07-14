defmodule Aiur.GitHub.AgentCommentOrigins do
  @moduledoc false

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.JsonStore

  @max_origins_per_ticket 100

  @spec record(String.t() | integer(), map()) :: :ok | {:error, term()}
  def record(ticket, verified_comment) when is_map(verified_comment) do
    with {:ok, ticket} <- normalize_ticket(ticket),
         {:ok, comment_id} <- comment_id(verified_comment) do
      persist(ticket, comment_id)
    end
  end

  def record(_ticket, _verified_comment), do: {:error, :invalid_verified_comment}

  @spec origin(String.t() | integer(), map()) :: :agent | :external
  def origin(ticket, comment) when is_map(comment) do
    with {:ok, ticket} <- normalize_ticket(ticket),
         {:ok, comment_id} <- comment_id(comment),
         {:ok, origins} <- load_origins() do
      if comment_id in Map.get(origins, ticket, []), do: :agent, else: :external
    else
      {:error, reason} ->
        Logger.warning("Agent comment origin lookup failed: ticket=#{inspect(ticket)} reason=#{inspect(reason)}")
        :external
    end
  end

  def origin(_ticket, _comment), do: :external

  @doc false
  @spec path_for() :: Path.t()
  def path_for do
    Application.get_env(:aiur, :agent_comment_origins_path) ||
      Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.agent-comment-origins.json")
  end

  defp persist(ticket, comment_id) do
    path = path_for()

    :global.trans({__MODULE__, path}, fn ->
      with {:ok, origins} <- load_origins(path) do
        ids = [comment_id | Map.get(origins, ticket, [])] |> Enum.uniq() |> Enum.take(@max_origins_per_ticket)
        JsonStore.write!(path, %{"origins" => Map.put(origins, ticket, ids)})
        :ok
      end
    end)
  rescue
    error -> {:error, {:persistence_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:persistence_failed, {kind, reason}}}
  end

  defp load_origins(path \\ path_for()) do
    case JsonStore.read(path, %{}) do
      {:ok, %{} = persisted} -> {:ok, normalize_origins(Map.get(persisted, "origins", %{}))}
      {:ok, _other} -> {:error, :invalid_store_shape}
      {:error, reason} -> {:error, {:store_read_failed, reason}}
    end
  end

  defp normalize_origins(origins) when is_map(origins) do
    Enum.reduce(origins, %{}, fn
      {ticket, ids}, acc when is_binary(ticket) and is_list(ids) ->
        normalized_ids =
          ids
          |> Enum.filter(&(is_binary(&1) and &1 != ""))
          |> Enum.uniq()
          |> Enum.take(@max_origins_per_ticket)

        if normalized_ids == [], do: acc, else: Map.put(acc, ticket, normalized_ids)

      _entry, acc ->
        acc
    end)
  end

  defp normalize_origins(_origins), do: %{}

  defp normalize_ticket(ticket) when is_integer(ticket), do: {:ok, Integer.to_string(ticket)}

  defp normalize_ticket(ticket) when is_binary(ticket) do
    case String.trim(ticket) do
      "" -> {:error, :invalid_ticket}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_ticket(_ticket), do: {:error, :invalid_ticket}

  defp comment_id(comment) do
    case Map.get(comment, "id") || Map.get(comment, :id) do
      id when is_integer(id) ->
        {:ok, Integer.to_string(id)}

      id when is_binary(id) ->
        case String.trim(id) do
          "" -> {:error, :missing_comment_id}
          normalized -> {:ok, normalized}
        end

      _other ->
        {:error, :missing_comment_id}
    end
  end
end
