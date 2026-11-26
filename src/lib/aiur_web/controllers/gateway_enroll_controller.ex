defmodule AiurWeb.GatewayEnrollController do
  @moduledoc """
  `POST /api/v1/gateway/enroll`: a joining gateway redeems a one-time invite.

  The invite secret is the credential, so the route has no auth pipeline. In one locked step the invite is
  burned, a peer-bound client token is minted and the joiner gets a registry entry with `read`. Invited
  write categories are not written here: they become a human-required `gateway_grant` Decision.
  Every refusal writes nothing and leaves one audit line. A remote IP gets 5 attempts a minute, then 429
  even for a correct secret; behind a proxy or tunnel every caller shares one address.
  """
  use Phoenix.Controller, formats: [:json]

  alias Aiur.ClientTokens
  alias Aiur.ControlCall.Audit
  alias Aiur.Gateway.{GrantRequest, Identity, Invites, Registry}
  alias AiurWeb.DashboardAuthRateLimit.Store

  require Logger

  @window_ms 60_000
  @limit 5
  @id ~r/\A[A-Za-z0-9]{8,64}\z/

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    cond do
      not AiurWeb.EndpointConfig.get(:gateway_hello, false) -> AiurWeb.ObservabilityApiController.not_found(conn, params)
      not allowed?(ip(conn)) -> refuse(conn, 429, :rate_limited)
      true -> enroll(conn, params)
    end
  end

  # Bounded by the store's own client cap and pruning; with no store (no dashboard listener) the route is not served either.
  defp allowed?(ip) do
    if Process.whereis(Store), do: Store.allow({:enroll, ip}, System.monotonic_time(:millisecond), @window_ms, @limit), else: true
  end

  defp enroll(conn, %{"id" => id, "secret" => secret, "gateway_id" => peer_id} = params) when is_binary(id) and is_binary(secret) do
    if Regex.match?(@id, peer_id) do
      case Invites.redeem(id, secret, System.os_time(:second), &register(&1, peer_id, params["label"])) do
        {:ok, body} -> succeed(conn, peer_id, Map.delete(body, :undo))
        {:error, {:burn_failed, %{undo: undo}}} -> undo_enrol(conn, undo)
        {:error, reason} -> refuse(conn, reason)
      end
    else
      refuse(conn, :invalid_request)
    end
  end

  defp enroll(conn, _params), do: refuse(conn, :invalid_request)

  # The invite could not be burned, so it must not stay usable for another gateway id: take the enrolment back.
  defp undo_enrol(conn, {name, token_name}) do
    ClientTokens.revoke(token_name)
    Registry.write(&Map.delete(&1, name), "invite_enrol_rollback")
    refuse(conn, :unavailable)
  end

  defp register(grants, peer_id, label) do
    with %{gateway_id: own} when is_binary(own) <- Identity.current(),
         {:ok, %{instances: instances}} <- Registry.get(),
         :ok <- unenrolled(instances, peer_id),
         name = free_name(instances, label || peer_id),
         token_name = "peer-" <> name <> "-1",
         write? = Enum.any?(grants, &(&1 != "read")),
         {:ok, token} <- ClientTokens.create(token_name, if(write?, do: "write", else: "read"), peer: peer_id, categories: grants),
         :ok <- write_entry(name, label, peer_id, token_name) do
      pending = grants -- ["read"]
      request_pending(%{name: name, label: label, gateway_id: peer_id}, pending)
      {:ok, %{gateway_id: own, label: Identity.current().gateway_label, token: token, granted: ["read"], pending: pending, undo: {name, token_name}}}
    else
      {:error, _reason} = error -> error
      _unavailable -> {:error, :unavailable}
    end
  end

  defp unenrolled(instances, peer_id) do
    if Enum.any?(instances, fn {_name, entry} -> entry["gateway_id"] == peer_id end), do: {:error, :duplicate_peer}, else: :ok
  end

  defp write_entry(name, label, peer_id, token_name) do
    entry = %{"gateway_id" => peer_id, "allows" => %{"categories" => ["read"], "credentials" => [token_name]}}
    entry = if plain?(label), do: Map.put(entry, "label", label), else: entry

    result = Registry.write(fn instances -> Map.put(instances, name, entry) end, "invite_enrol")
    if result != :ok, do: ClientTokens.revoke(token_name)
    result
  end

  defp request_pending(_peer, []), do: :ok

  defp request_pending(peer, pending) do
    case GrantRequest.request(peer, pending) do
      {:ok, _decision} -> :ok
      {:error, reason} -> Logger.warning("could not raise the grant Decision for #{peer.gateway_id}: #{inspect(reason)}; use `aiur gateway grant`")
    end
  end

  defp free_name(instances, label) do
    base = label |> to_string() |> String.replace(~r/[^A-Za-z0-9._-]/, "-") |> String.slice(0, 40) |> String.trim("-")
    base = if base in ["", "all"], do: "peer", else: base
    Enum.find(Stream.concat([base], Stream.map(2..99, &"#{base}-#{&1}")), "#{base}-#{System.unique_integer([:positive])}", &(not Map.has_key?(instances, &1)))
  end

  defp plain?(value), do: is_binary(value) and value != "" and not String.contains?(value, ["\"", "'", "\\", "\n", "\t"])

  defp succeed(conn, peer_id, body) do
    Audit.append(%{at: now(), event: "enrolled", peer: peer_id, remote_ip: format(ip(conn)), categories: body.granted, pending: body.pending})
    conn |> no_store() |> json(body)
  end

  defp refuse(conn, reason), do: refuse(conn, status(reason), reason)

  defp refuse(conn, status, reason) do
    Audit.append(%{at: now(), event: "enroll_refused", outcome: "refused", reason: reason, remote_ip: format(ip(conn))})
    # Unknown id and wrong secret share one body so a caller cannot probe ids.
    conn |> no_store() |> put_status(status) |> json(%{error: code(reason)})
  end

  defp status(:invalid_invite), do: 401
  defp status(reason) when reason in [:expired, :used], do: 410
  defp status(:duplicate_peer), do: 409
  defp status(:invalid_request), do: 400
  defp status(_unavailable), do: 503

  defp code(:used), do: "invite_used"
  defp code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp code(_reason), do: "unavailable"

  defp no_store(conn), do: Plug.Conn.put_resp_header(conn, "cache-control", "no-store")
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp ip(conn), do: conn.remote_ip
  defp format(ip), do: ip |> :inet.ntoa() |> to_string()
end
