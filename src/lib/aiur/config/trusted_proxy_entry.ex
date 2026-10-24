defmodule Aiur.Config.TrustedProxyEntry do
  @moduledoc false

  @spec valid?(String.t()) :: boolean()
  def valid?("platform"), do: true

  def valid?(entry) when is_binary(entry) do
    case String.split(entry, "/", parts: 2) do
      [address] ->
        match?({:ok, _}, :inet.parse_address(String.to_charlist(address)))

      [address, bits] ->
        with {:ok, ip} <- :inet.parse_address(String.to_charlist(address)),
             width <- if(tuple_size(ip) == 4, do: 32, else: 128),
             {prefix, ""} <- Integer.parse(bits),
             true <- prefix >= 0 and prefix <= width do
          true
        else
          _ -> false
        end
    end
  end

  def valid?(_), do: false
end
