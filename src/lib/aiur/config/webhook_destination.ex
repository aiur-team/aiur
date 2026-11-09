defmodule Aiur.Config.WebhookDestination do
  @moduledoc "Validates and pins outbound webhook destinations to a resolved address."

  import Bitwise

  @type resolver :: (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term()})

  @spec validate_url(term(), boolean()) :: :ok | {:error, String.t()}
  def validate_url(value, allow_private_destinations?) when is_binary(value) do
    with {:ok, uri} <- parse_url(value),
         :ok <- validate_literal(uri.host, allow_private_destinations?) do
      :ok
    else
      {:error, :private_destination_forbidden} ->
        {:error, "must not use a private, loopback, link-local, CGNAT, ULA or unspecified address"}

      {:error, _reason} = error ->
        error
    end
  end

  def validate_url(_value, _allow_private_destinations?), do: {:error, "must be an HTTPS URL"}

  @doc "Resolves the host once and returns a URL pinned to the validated address."
  @spec resolve(String.t(), boolean(), resolver()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def resolve(value, allow_private_destinations?, resolver \\ &default_resolver/1) do
    with {:ok, uri} <- parse_url(value),
         {:ok, addresses} <- addresses(uri.host, resolver),
         :ok <- validate_addresses(addresses, allow_private_destinations?),
         [address | _rest] <- addresses do
      pinned_url = uri |> Map.put(:host, address_to_string(address)) |> URI.to_string()
      {:ok, pinned_url, uri.host}
    else
      [] -> {:error, :destination_did_not_resolve}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec restricted_address?(:inet.ip_address()) :: boolean()
  def restricted_address?({0, _, _, _}), do: true
  def restricted_address?({10, _, _, _}), do: true
  def restricted_address?({100, second, _, _}) when second in 64..127, do: true
  def restricted_address?({127, _, _, _}), do: true
  def restricted_address?({169, 254, _, _}), do: true
  def restricted_address?({172, second, _, _}) when second in 16..31, do: true
  def restricted_address?({192, 168, _, _}), do: true
  def restricted_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  def restricted_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  def restricted_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    restricted_address?({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})
  end

  def restricted_address?({first, _, _, _, _, _, _, _}) when (first &&& 0xFE00) == 0xFC00, do: true
  def restricted_address?({first, _, _, _, _, _, _, _}) when (first &&& 0xFFC0) == 0xFE80, do: true
  def restricted_address?(_address), do: false

  defp parse_url(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil} = uri}
      when is_binary(host) and host != "" ->
        {:ok, uri}

      _other ->
        {:error, "must be an HTTPS URL with a host and without userinfo or a fragment"}
    end
  end

  defp validate_literal(host, allow_private_destinations?) do
    case parse_address(host) do
      {:ok, address} -> validate_addresses([address], allow_private_destinations?)
      :error -> :ok
    end
  end

  defp addresses(host, resolver) do
    case parse_address(host) do
      {:ok, address} -> {:ok, [address]}
      :error -> resolver.(host)
    end
  rescue
    _error -> {:error, :destination_resolution_failed}
  catch
    _kind, _reason -> {:error, :destination_resolution_failed}
  end

  defp validate_addresses([], _allow_private_destinations?), do: {:error, :destination_did_not_resolve}

  defp validate_addresses(addresses, allow_private_destinations?) do
    cond do
      Enum.any?(addresses, &unusable_address?/1) -> {:error, :private_destination_forbidden}
      allow_private_destinations? -> :ok
      Enum.any?(addresses, &restricted_address?/1) -> {:error, :private_destination_forbidden}
      true -> :ok
    end
  end

  defp unusable_address?({0, _, _, _}), do: true
  defp unusable_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true

  defp unusable_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    unusable_address?({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})
  end

  defp unusable_address?(_address), do: false

  defp parse_address(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  defp default_resolver(host) do
    host = String.to_charlist(host)

    [:inet, :inet6]
    |> Enum.reduce([], fn family, addresses ->
      case :inet.getaddrs(host, family) do
        {:ok, resolved} -> addresses ++ resolved
        {:error, _reason} -> addresses
      end
    end)
    |> Enum.uniq()
    |> case do
      [] -> {:error, :destination_did_not_resolve}
      addresses -> {:ok, addresses}
    end
  end

  defp address_to_string(address), do: address |> :inet.ntoa() |> List.to_string()
end
