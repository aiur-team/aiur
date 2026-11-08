defmodule Aiur.Gateway.Hello do
  @moduledoc """
  The anonymous `GET /api/v1/gateway/hello` body: exactly five keys, nothing else.

  `enabled?/2` resolves `server.gateway_hello`: an explicit boolean wins, otherwise the route is
  on for a loopback or tailnet bind and off for any other (LAN, public) bind.
  """

  import Bitwise

  alias Aiur.Gateway.{Identity, Invites}

  @keys ~w(gateway_id gateway_label build tls_fingerprint_sha256 enrollment)a

  @spec keys() :: [atom()]
  def keys, do: @keys

  @spec body() :: map()
  def body do
    identity = Identity.current()

    %{
      gateway_id: identity.gateway_id,
      gateway_label: identity.gateway_label,
      build: to_string(Application.spec(:aiur, :vsn) || "unknown"),
      # The daemon never terminates TLS itself, so the pin is the operator-supplied SPKI hash or nil.
      tls_fingerprint_sha256: tls_pin(),
      enrollment: if(Invites.open?(), do: "open", else: "closed")
    }
  end

  @doc "`server.tls_pin_sha256`, or nil when unset or the config cannot be read."
  @spec tls_pin() :: String.t() | nil
  def tls_pin do
    case Aiur.Config.settings() do
      {:ok, settings} -> settings.server.tls_pin_sha256
      _unavailable -> nil
    end
  end

  @spec enabled?(boolean() | nil, :inet.ip_address()) :: boolean()
  def enabled?(setting, _ip) when is_boolean(setting), do: setting
  def enabled?(nil, ip), do: loopback?(ip) or tailnet_ip?(ip)

  @doc "IPv4 in 100.64.0.0/10 or IPv6 in fd7a:115c:a1e0::/48."
  @spec tailnet_ip?(:inet.ip_address()) :: boolean()
  def tailnet_ip?({100, b, _, _}), do: (b &&& 0xC0) == 64
  def tailnet_ip?({0xFD7A, 0x115C, 0xA1E0, _, _, _, _, _}), do: true
  def tailnet_ip?(_ip), do: false

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_ip), do: false
end
