defmodule Aiur.EventPublicationLog do
  @moduledoc """
  Persists locally-known event publication outcomes independently of agent transcripts.

  Remote workers own their transcript files, but publication happens in the local
  Aiur runtime. Keeping these small coordination facts in a separate local stream
  avoids duplicate transcript ownership while retaining eventual delivery evidence.
  """

  alias Aiur.Workspace.Reconstruction

  @relative_path "logs/event-publications.ndjson"

  @doc """
  Appends one publication outcome to the workspace-local durable stream.
  """
  @spec write(Path.t() | nil, map()) :: :ok | {:error, term()}
  def write(workspace, record) when is_binary(workspace) and is_map(record) do
    Reconstruction.with_log_lock(workspace, fn ->
      path = Path.join(workspace, @relative_path)

      with :ok <- File.mkdir_p(Path.dirname(path)),
           {:ok, encoded} <- Jason.encode(json_safe(record)) do
        File.write(path, encoded <> "\n", [:append, :sync])
      end
    end)
  rescue
    error -> {:error, {:publication_log_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:publication_log_failure, kind, reason}}
  end

  def write(nil, _record), do: :ok
  def write(_workspace, _record), do: {:error, :invalid_publication_record}

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%{} = value), do: Map.new(value, fn {key, item} -> {json_key(key), json_safe(item)} end)
  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  defp json_safe(value) when is_boolean(value) or is_nil(value), do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_binary(value) or is_number(value), do: value
  defp json_safe(value), do: inspect(value)

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key), do: inspect(key)
end
