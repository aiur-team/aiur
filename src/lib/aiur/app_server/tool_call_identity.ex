defmodule Aiur.AppServer.ToolCallIdentity do
  @moduledoc false

  alias Aiur.AppServer.Messages

  @type resolution ::
          :untracked
          | {:ok, term(), binary()}
          | {:error, :missing_thread_identity}

  @spec resolve(term(), map(), term(), term(), term()) :: resolution()
  def resolve(scope, params, tool_name, arguments, fallback_thread_id) do
    call_id = Messages.tool_call_id(params, nil)

    cond do
      is_nil(scope) or is_nil(call_id) ->
        :untracked

      is_nil(thread_id(params, fallback_thread_id)) ->
        {:error, :missing_thread_identity}

      true ->
        thread_id = thread_id(params, fallback_thread_id)
        identity = {scope, thread_id, call_id}
        {:ok, identity, fingerprint(params, tool_name, arguments)}
    end
  end

  defp fingerprint(params, tool_name, arguments) do
    invocation = %{
      version: 1,
      turn_id: field(params, ["turnId", :turnId, "turn_id", :turn_id]),
      tool: tool_name,
      namespace:
        field(params, [
          "namespace",
          :namespace,
          "server",
          :server,
          "serverName",
          :serverName,
          "mcpServer",
          :mcpServer
        ]),
      arguments: normalize(arguments)
    }

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(invocation, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp thread_id(params, fallback) do
    field(params, ["threadId", :threadId, "thread_id", :thread_id]) || fallback
  end

  defp field(params, keys) when is_map(params) do
    Enum.find_value(keys, &Map.get(params, &1))
  end

  defp field(_params, _keys), do: nil

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {normalize_key(key), normalize(nested)} end)
  end

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&normalize/1)
  defp normalize(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key
end
