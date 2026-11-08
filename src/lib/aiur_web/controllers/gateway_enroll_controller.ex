defmodule AiurWeb.GatewayEnrollController do
  @moduledoc """
  `POST /api/v1/gateway/enroll`: a joining gateway redeems a one-time invite.

  The invite secret is the credential, so the route has no auth pipeline. In one locked step the invite is
  burned, a peer-bound client token is minted and the joiner gets a registry entry with `read`. Invited
  write categories are not written here: they become a human-required `gateway_grant` Decision.
  Every refusal writes nothing and leaves one audit line. Five refusals per minute per remote IP
  block that IP, even for a correct secret.
  """
  use Phoenix.Controller, formats: [:json]

  alias Aiur.ClientTokens
  alias Aiur.ControlCall.Audit
  alias Aiur.Gateway.{GrantRequest, Identity, Invites, Registry}

  require Logger

  @window 60
  @max_failures 5
  @id ~r/\A[A-Za-z0-9]{8,64}\z/

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    cond do
      not AiurWeb.EndpointConfig.get(:gateway_hello, false) -> AiurWeb.ObservabilityApiController.not_found(conn, params)
      blocked?(ip(conn)) -> refuse(conn, 429, :rate_limited)
      true -> enroll(conn, params)
    end
  end

  defp enroll(conn, %{"id" => id, "secret" => secret, "gateway_id" => peer_id} = params) when is_binary(id) and is_binary(secret) do
    if Regex.match?(@id, peer_id) do
      case Invites.redeem(id, secret, System.os_time(:second), &register(&1, peer_id, params["label"])) do
        {:ok, body} -> succeed(conn, peer_id, body)
        {:error, reason} -> refuse(conn, reason)
      end
    else
      refuse(conn, :invalid_request)
    end
  end

  defp enroll(conn, _params), do: refuse(conn, :invalid_request)

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
      {:ok, %{gateway_id: own, label: Identity.current().gateway_label, token: token, granted: ["read"], pending: pending}}
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

  defp refuse(conn, reason) do
    record_failure(ip(conn))
    refuse(conn, status(reason), reason)
  end

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

  # ponytail: failures live in :persistent_term, so they reset on restart and only suit this low-rate route.
  defp key(ip), do: {__MODULE__, :failures, ip}

  defp recent(ip, at \\ System.monotonic_time(:second)), do: :persistent_term.get(key(ip), []) |> Enum.filter(&(at - &1 < @window))

  defp blocked?(ip), do: length(recent(ip)) >= @max_failures

  defp record_failure(ip) do
    :global.trans({{__MODULE__, :failures}, self()}, fn ->
      :persistent_term.put(key(ip), [System.monotonic_time(:second) | recent(ip)])
    end)
  end

  @doc false
  @spec reset_failures(:inet.ip_address()) :: :ok
  def reset_failures(ip) do
    :persistent_term.erase(key(ip))
    :ok
  end
end
