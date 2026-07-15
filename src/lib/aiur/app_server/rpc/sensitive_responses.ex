defmodule Aiur.AppServer.Rpc.SensitiveResponses do
  @moduledoc false

  @key {Aiur.AppServer.Rpc, :late_sensitive_response_ids}
  @partial_key {Aiur.AppServer.Rpc, :late_sensitive_response_partials}

  @spec retain(port(), integer()) :: :ok
  def retain(port, request_id), do: retain(port, request_id, false)

  @spec retain(port(), integer(), boolean()) :: :ok
  def retain(port, request_id, partial_line?) when is_port(port) and is_integer(request_id) and is_boolean(partial_line?) do
    ids = @key |> Process.get(MapSet.new()) |> MapSet.put({port, request_id})
    Process.put(@key, ids)

    if partial_line? do
      partials = @partial_key |> Process.get(MapSet.new()) |> MapSet.put({port, request_id})
      Process.put(@partial_key, partials)
    end

    :ok
  end

  @spec clear(port()) :: :ok
  def clear(port) when is_port(port) do
    ids = @key |> Process.get(MapSet.new()) |> MapSet.reject(fn {retained_port, _request_id} -> retained_port == port end)
    put_ids(ids)

    partials =
      @partial_key
      |> Process.get(MapSet.new())
      |> MapSet.reject(fn {retained_port, _request_id} -> retained_port == port end)

    put_partials(partials)
  end

  @spec discard?(port(), binary() | map()) :: boolean()
  def discard?(port, data) when is_port(port) do
    case take_partial(port) do
      :none ->
        discard_response(port, data)

      {:ok, request_id} ->
        ids() |> MapSet.delete({port, request_id}) |> put_ids()
        true
    end
  end

  defp discard_response(port, data) do
    case response_id(data) do
      {:ok, request_id} -> discard_retained_response?(port, request_id)
      :not_a_response -> false
      :malformed -> malformed_sensitive_response?(port, data)
    end
  end

  defp discard_retained_response?(port, request_id) do
    if MapSet.member?(ids(), {port, request_id}) do
      ids() |> MapSet.delete({port, request_id}) |> put_ids()
      true
    else
      false
    end
  end

  defp response_id(%{"id" => request_id, "result" => _result}) when is_integer(request_id), do: {:ok, request_id}
  defp response_id(%{"id" => request_id, "error" => _error}) when is_integer(request_id), do: {:ok, request_id}
  defp response_id(%{"method" => _method, "result" => _result}), do: :malformed
  defp response_id(%{"method" => _method, "error" => _error}), do: :malformed
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
        retained_for_port?(port)
    end
  end

  defp malformed_sensitive_response?(_port, _data), do: false

  defp ids, do: Process.get(@key, MapSet.new())

  defp take_partial(port) do
    case Enum.find(partials(), fn {retained_port, _request_id} -> retained_port == port end) do
      {^port, request_id} = partial ->
        partials() |> MapSet.delete(partial) |> put_partials()
        {:ok, request_id}

      nil ->
        :none
    end
  end

  defp retained_for_port?(port), do: Enum.any?(ids(), fn {retained_port, _request_id} -> retained_port == port end)

  defp partials, do: Process.get(@partial_key, MapSet.new())

  defp put_ids(ids) do
    if MapSet.size(ids) == 0, do: Process.delete(@key), else: Process.put(@key, ids)
    :ok
  end

  defp put_partials(partials) do
    if MapSet.size(partials) == 0, do: Process.delete(@partial_key), else: Process.put(@partial_key, partials)
    :ok
  end
end
