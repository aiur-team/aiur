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
    # @config-reference config-configuration-18 server.tailscale_funnel
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail server.tailscale_funnel | boolean | false | Reconcile an already-enabled Tailscale Funnel HTTPS route on port 443 to the dashboard's current bound host and port at startup and every 30 seconds. Requires the Tailscale CLI and an existing Funnel route; failures raise a Build Order Funnel alert and retry. |
    field(:tailscale_funnel, :boolean, default: false)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:port, :host, :public_url, :allowed_hosts, :tailscale_funnel], empty_values: [])
    |> validate_number(:port, greater_than_or_equal_to: 0)
  end
end
