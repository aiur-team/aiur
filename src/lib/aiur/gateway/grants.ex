defmodule Aiur.Gateway.Grants do
  @moduledoc """
  What a peer gateway may do on this gateway: the receiver-side half of the permission check.

  The token's own categories are checked first by the caller. This checks the peer's `allows` block in
  `Aiur.Gateway.Registry`: its category list, and its credential list when that is non-empty.
  """

  alias Aiur.Gateway.Registry

  @type reason :: {:category_not_granted, String.t()} | :unknown_peer | :grants_unavailable

  @spec allowed?(String.t(), String.t() | nil, atom() | String.t()) :: :ok | {:error, reason()}
  def allowed?(peer_id, token_id, category) when is_binary(peer_id) do
    category = to_string(category)

    case Registry.get() do
      {:error, _reason} -> {:error, :grants_unavailable}
      {:ok, %{peers: peers}} -> peers |> Map.values() |> Enum.find(&(&1.gateway_id == peer_id)) |> check(token_id, category)
    end
  end

  defp check(nil, _token_id, _category), do: {:error, :unknown_peer}

  defp check(peer, token_id, category) do
    if category in peer.categories and (peer.credentials == [] or token_id in peer.credentials),
      do: :ok,
      else: {:error, {:category_not_granted, category}}
  end
end
