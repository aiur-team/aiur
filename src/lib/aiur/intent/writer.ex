defmodule Aiur.Intent.Writer do
  @moduledoc """
  The one entry point for authoring a shared-intent change. Never needs the database:
  stamp the HLC, append to the outbox and local cache, then nudge the sync loop.
  """

  alias Aiur.Gateway.Identity
  alias Aiur.Intent.{Change, Hlc, Store, Sync}

  @spec write(map() | keyword(), keyword()) :: {:ok, Change.t()} | {:error, atom()}
  def write(attrs, opts \\ []) do
    with {:ok, gateway} <- gateway_id(),
         change = Change.new(attrs) |> Map.put(:origin_gateway, gateway) |> Map.merge(%{hlc_wall_ms: 0, hlc_counter: 0}),
         :ok <- Change.validate(change),
         {:ok, {wall, counter}} <- Hlc.tick(Keyword.get(opts, :hlc, Hlc)),
         change = %{change | hlc_wall_ms: wall, hlc_counter: counter},
         :ok <- Store.append_local(Keyword.get(opts, :store, Store), change) do
      Sync.nudge(Keyword.get(opts, :sync, Sync))
      {:ok, change}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _} -> {:error, :write_failed}
    end
  end

  defp gateway_id do
    case Identity.current() do
      %{gateway_id: id} when is_binary(id) -> {:ok, id}
      _ -> {:error, :gateway_identity_unavailable}
    end
  end
end
