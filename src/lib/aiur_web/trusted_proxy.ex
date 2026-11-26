defmodule AiurWeb.TrustedProxy do
  @moduledoc "Applies forwarded request metadata only when the socket peer is trusted."

  @behaviour Plug
  import Plug.Conn
  import Bitwise

  alias Aiur.Config.TrustedProxyEntry

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    proxies = Aiur.Config.settings!().server |> Map.get(:trusted_proxies, [])

    apply_forwarded_headers(conn, proxies)
  end

  @doc false
  @spec apply_forwarded_headers(Plug.Conn.t(), [String.t()]) :: Plug.Conn.t()
  def apply_forwarded_headers(conn, proxies) do
    if trusted?(conn.remote_ip, proxies) do
      conn
      |> forwarded_scheme()
      |> forwarded_host()
      |> forwarded_client_ip(proxies)
    else
      conn
    end
  end

  @doc false
  @spec valid_entry?(String.t()) :: boolean()
  def valid_entry?(entry), do: TrustedProxyEntry.valid?(entry)

  @doc false
  @spec trusted?(:inet.ip_address(), [String.t()]) :: boolean()
  def trusted?(ip, proxies) do
    Enum.any?(List.wrap(proxies), fn
      "platform" -> private_address?(ip)
      cidr -> cidr_contains?(ip, cidr)
    end)
  end

  defp forwarded_scheme(conn) do
    case conn |> get_req_header("x-forwarded-proto") |> last_header_value() |> String.downcase() do
      "https" -> %{conn | scheme: :https}
      "http" -> %{conn | scheme: :http}
      _ -> conn
    end
  end

  defp forwarded_host(conn) do
    value = conn |> get_req_header("x-forwarded-host") |> last_header_value()

    case URI.parse("//" <> value) do
      %URI{host: host, port: port, path: nil, query: nil, fragment: nil, userinfo: nil}
      when is_binary(host) ->
        default_port = if conn.scheme == :https, do: 443, else: 80
        %{conn | host: host, port: port || default_port}

      _ ->
        conn
    end
  end

  defp forwarded_client_ip(conn, proxies) do
    forwarded = get_req_header(conn, "x-forwarded-for")

    with value when value != "" <- Enum.join(forwarded, ","),
         {:ok, addresses} <- parse_forwarded_addresses(value),
         chain <- addresses ++ [conn.remote_ip],
         client when not is_nil(client) <- Enum.find(Enum.reverse(chain), &(not trusted?(&1, proxies))) do
      %{conn | remote_ip: client}
    else
      _ -> conn
    end
  end

  defp parse_forwarded_addresses(value) do
    value
    |> String.split(",")
    |> Enum.map(&parse_ip(String.trim(&1)))
    |> then(fn parsed ->
      if Enum.all?(parsed, &match?({:ok, _}, &1)), do: {:ok, Enum.map(parsed, fn {:ok, ip} -> ip end)}, else: :error
    end)
  end

  defp last_header_value([]), do: ""
  defp last_header_value(values), do: values |> List.last() |> String.split(",") |> List.last() |> String.trim()

  defp cidr_contains?(ip, cidr) do
    with [address | suffix] <- String.split(cidr, "/", parts: 2),
         {:ok, network} <- parse_ip(address),
         true <- address_width(ip) == address_width(network),
         {width, _} <- address_width(ip),
         bits <- List.first(suffix) || Integer.to_string(width),
         {prefix, ""} <- Integer.parse(bits),
         true <- prefix >= 0 and prefix <= width do
      mask = if prefix == 0, do: 0, else: ((1 <<< prefix) - 1) <<< (width - prefix)
      (ip_integer(ip) &&& mask) == (ip_integer(network) &&& mask)
    else
      _ -> false
    end
  end

  defp private_address?({10, _, _, _}), do: true
  defp private_address?({172, second, _, _}) when second in 16..31, do: true
  defp private_address?({192, 168, _, _}), do: true
  defp private_address?({169, 254, _, _}), do: true
  defp private_address?({a, _b, _, _, _, _, _, _}) when (a &&& 0xFE00) == 0xFC00, do: true
  defp private_address?({a, b, _, _, _, _, _, _}) when a == 0xFE80 and (b &&& 0xFFC0) == 0, do: true
  defp private_address?(_), do: false

  defp parse_ip(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> {:ok, ip}
      _ -> :error
    end
  end

  defp address_width({_, _, _, _}), do: {32, :ipv4}
  defp address_width({_, _, _, _, _, _, _, _}), do: {128, :ipv6}

  defp ip_integer({a, b, c, d}), do: Enum.reduce([a, b, c, d], 0, &((&2 <<< 8) + &1))
  defp ip_integer(parts) when tuple_size(parts) == 8, do: Enum.reduce(Tuple.to_list(parts), 0, &((&2 <<< 16) + &1))
end
