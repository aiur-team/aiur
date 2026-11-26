defmodule Aiur.Config.TrustedProxyEntry do
  @moduledoc false

  @spec valid?(String.t()) :: boolean()
  def valid?("platform"), do: true

  def valid?(entry) when is_binary(entry) do
    case String.split(entry, "/", parts: 2) do
      [address] ->
        match?({:ok, _}, :inet.parse_address(String.to_charlist(address)))

      [address, bits] ->
        valid_cidr?(address, bits)
    end
  end

  def valid?(_), do: false

  defp valid_cidr?(address, bits) do
    with {:ok, ip} <- :inet.parse_address(String.to_charlist(address)),
         {prefix, ""} <- Integer.parse(bits) do
      prefix >= 0 and prefix <= address_width(ip)
    else
      _ -> false
    end
  end

  defp address_width(ip) when tuple_size(ip) == 4, do: 32
  defp address_width(_ip), do: 128
end
