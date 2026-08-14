defmodule AiurWeb.OperatorControlCenter.RowToken do
  @moduledoc """
  Derives the opaque server-lookup token for one tracker-identified table row.

  Both the Units catalog and the Tickets panel address rows by token rather than
  by display identifier, so the derivation lives in one place: two copies could
  drift and silently stop resolving each other's rows.
  """

  alias Aiur.TrackerIdentity

  @doc "Returns a stable opaque token for a joinable identity, or `nil`."
  @spec for(term()) :: String.t() | nil
  def for(%TrackerIdentity{} = identity) do
    case TrackerIdentity.github_key(identity) do
      nil -> nil
      key -> key |> :erlang.term_to_binary() |> then(&:crypto.hash(:sha256, &1)) |> Base.url_encode64(padding: false)
    end
  end

  def for(%{identity: identity}), do: __MODULE__.for(identity)
  def for(_row), do: nil
end
