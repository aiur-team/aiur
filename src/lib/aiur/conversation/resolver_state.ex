defmodule Aiur.Conversation.ResolverState do
  @moduledoc false
  alias Aiur.Config.Paths

  @spec load() :: {Path.t() | nil, map(), map()}
  def load do
    case Paths.conversation_state_dir() do
      {:ok, root} -> {root, cursor(root), decisions(root)}
      _ -> {nil, %{}, %{}}
    end
  end

  @spec save(Path.t() | nil, map()) :: :ok | {:error, term()}
  def save(nil, _cursor), do: {:error, :unavailable}

  def save(root, cursor) do
    with :ok <- Aiur.Journal.ensure_directory(root) do
      Aiur.Fs.atomic_write(Path.join(root, "resolver.json"), Jason.encode!(cursor), fsync: true, mode: 0o600)
    end
  end

  @spec remember(map(), map()) :: map()
  def remember(index, %{"subject_ref" => %{"decision_id" => id}, "kind" => "command_requested", "precision" => precision} = anchor)
      when is_binary(id) and precision in ["unanchored", "observed", "causal", "exact"] do
    prior = Map.get(index, id)
    selected = Enum.max_by(List.wrap(prior) ++ [anchor], &precision/1)
    Map.put(index, id, selected)
  end

  def remember(index, _anchor), do: index

  defp precision(anchor), do: Map.fetch!(%{"unanchored" => 0, "observed" => 1, "causal" => 2, "exact" => 3}, anchor["precision"])

  defp cursor(root) do
    with {:ok, bytes} <- File.read(Path.join(root, "resolver.json")),
         {:ok, cursor} when is_map(cursor) <- Jason.decode(bytes) do
      case cursor["last_event_id"] do
        id when is_integer(id) and id > 0 -> %{"last_event_id" => id}
        _ -> %{}
      end
    else
      _ -> %{}
    end
  end

  defp decisions(root) do
    # Rebuild the Command index, without replaying missed bus events.
    Path.wildcard(Path.join([root, "conv_*", "anchors.jsonl"]))
    |> Enum.reduce(%{}, fn path, index ->
      case File.read(path) do
        {:ok, bytes} -> Enum.reduce(String.split(bytes, "\n") |> Enum.drop(-1), index, &decode/2)
        _ -> index
      end
    end)
  end

  defp decode(line, index) do
    case Jason.decode(line) do
      {:ok, anchor} -> remember(index, anchor)
      _ -> index
    end
  end
end
