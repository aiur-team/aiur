defmodule Aiur.Config.Schema.Server do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # 0 = bind a free OS-assigned loopback port. The dashboard must bind so
    # claude remote-control's transcript hook can reach it; without a bound
    # port the hook is skipped and RC runs fail `:no_transcript`. Set an
    # explicit port to expose the dashboard at a fixed address.
    # @config-reference config-configuration-18 server.port
    # @config-detail server.port | integer | 0 | HTTP port; 0 selects a free OS port. |
    field(:port, :integer, default: 0)
    # @config-reference config-configuration-18 server.host
    # @config-detail server.host | string | `127.0.0.1` | HTTP bind address. `0.0.0.0` exposes the dashboard to the LAN; there is no automatic Tailscale detection. |
    field(:host, :string, default: "127.0.0.1")
    # @config-reference config-configuration-18 server.public_url
    # @config-detail server.public_url | string | nil | Public URL for generated links and Host/origin allowlists; loopback listeners also accept tailnet hosts. |
    field(:public_url, :string)
    # @config-reference config-configuration-18 server.allowed_hosts
    # @config-detail server.allowed_hosts | array | derived | Additional accepted Host names; the public URL host and loopback addresses are always accepted. |
    field(:allowed_hosts, {:array, :string})
    # @config-reference config-configuration-18 server.trusted_proxies
    # @config-detail server.trusted_proxies | array | `[]` | CIDRs allowed to set X-Forwarded-* request metadata; `platform` trusts private proxy-network peers. |
    field(:trusted_proxies, {:array, :string}, default: [])
    # @config-reference config-configuration-18 server.tailscale_funnel
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail server.tailscale_funnel | boolean | false | Reconcile an already-enabled Tailscale Funnel HTTPS route on port 443 to the dashboard's current bound host and port at startup and every 30 seconds. Requires the Tailscale CLI and an existing Funnel route; failures raise a Build Order Funnel alert and retry. |
    field(:tailscale_funnel, :boolean, default: false)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:port, :host, :public_url, :allowed_hosts, :trusted_proxies, :tailscale_funnel], empty_values: [])
    |> validate_number(:port, greater_than_or_equal_to: 0)
    |> validate_change(:trusted_proxies, fn :trusted_proxies, entries ->
      if Enum.all?(entries, &valid_proxy_entry?/1), do: [], else: [trusted_proxies: "must contain CIDRs or \"platform\""]
    end)
  end

  defp valid_proxy_entry?("platform"), do: true

  defp valid_proxy_entry?(entry) when is_binary(entry) do
    case String.split(entry, "/", parts: 2) do
      [address] ->
        match?({:ok, _}, :inet.parse_address(String.to_charlist(address)))

      [address, bits] ->
        with {:ok, ip} <- :inet.parse_address(String.to_charlist(address)),
             width <- address_width(ip),
             {prefix, ""} <- Integer.parse(bits),
             true <- prefix >= 0 and prefix <= width do
          true
        else
          _ -> false
        end
    end
  end

  defp valid_proxy_entry?(_), do: false

  defp address_width(ip) when tuple_size(ip) == 4, do: 32
  defp address_width(_ip), do: 128
end
