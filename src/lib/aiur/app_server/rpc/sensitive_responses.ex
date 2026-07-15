defmodule Aiur.AppServer.Rpc.SensitiveResponses do
  @moduledoc false

  @key {Aiur.AppServer.Rpc, :late_sensitive_response_ids}

  @spec retain(port(), integer()) :: :ok
  def retain(port, request_id) when is_port(port) and is_integer(request_id) do
    ids = @key |> Process.get(MapSet.new()) |> MapSet.put({port, request_id})
    Process.put(@key, ids)
    :ok
  end

  @spec clear(port()) :: :ok
  def clear(port) when is_port(port) do
    ids = @key |> Process.get(MapSet.new()) |> MapSet.reject(fn {retained_port, _request_id} -> retained_port == port end)
    put_ids(ids)
  end

  @spec discard?(port(), binary() | map()) :: boolean()
  def discard?(port, data) when is_port(port) do
    case response_id(data) do
      {:ok, request_id} ->
        if MapSet.member?(ids(), {port, request_id}) do
          ids() |> MapSet.delete({port, request_id}) |> put_ids()
          true
        else
          false
        end

      :not_a_response ->
        false

      :malformed ->
        malformed_sensitive_response?(port, data)
    end
  end

  defp response_id(%{"id" => request_id, "result" => _result}) when is_integer(request_id), do: {:ok, request_id}
  defp response_id(%{"id" => request_id, "error" => _error}) when is_integer(request_id), do: {:ok, request_id}
  defp response_id(%{"method" => _method}), do: :not_a_response
  defp response_id(%{"id" => request_id}) when is_integer(request_id), do: {:ok, request_id}
  defp response_id(%{"id" => _request_id}), do: :malformed
  defp response_id(%{}), do: :not_a_response

  defp response_id(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, payload} when is_map(payload) -> response_id(payload)
      _ -> :malformed
    end
  end

  defp response_id(_data), do: :malformed

  defp malformed_sensitive_response?(port, data) when is_map(data) do
    Enum.any?(ids(), fn {retained_port, _request_id} -> retained_port == port end)
  end

  defp malformed_sensitive_response?(port, data) when is_binary(data) do
    case Enum.find(ids(), fn
           {^port, request_id} ->
             String.match?(data, ~r/"(?:i|\\u0069)(?:d|\\u0064)"\s*:\s*#{request_id}(?=\s*[,}])/)

           _retained ->
             false
         end) do
      {^port, request_id} ->
        ids() |> MapSet.delete({port, request_id}) |> put_ids()
        true

      nil ->
        false
    end
  end

  defp malformed_sensitive_response?(_port, _data), do: false

  defp ids, do: Process.get(@key, MapSet.new())

  defp put_ids(ids) do
    if MapSet.size(ids) == 0, do: Process.delete(@key), else: Process.put(@key, ids)
    :ok
  end
end
