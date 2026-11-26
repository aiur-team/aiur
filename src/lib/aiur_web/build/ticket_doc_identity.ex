defmodule AiurWeb.Build.TicketDocIdentity do
  @moduledoc false
  alias Aiur.BuildOrder.{History, TicketDetail}
  alias Aiur.{OpenTicketSource, TrackerIdentity}

  @spec live_identity(String.t(), keyword()) :: {:ok, TrackerIdentity.t()} | :no_identity | {:error, term()}
  def live_identity(id, opts) do
    snapshot = Keyword.get(opts, :snapshot_fun, &OpenTicketSource.snapshot/0).()
    ticket = Enum.find(snapshot.tickets, &(&1.identifier == id and TrackerIdentity.joinable?(&1.identity)))

    case ticket do
      %{identity: identity} -> {:ok, identity}
      nil -> history_identity(id, snapshot, opts)
    end
  end

  defp history_identity(_id, %{status: :unsupported}, _opts), do: :no_identity

  defp history_identity(id, snapshot, opts) do
    rows = Keyword.get(opts, :history_fun, &History.rows/1).([String.to_integer(id)])

    with {:ok, [%{node_id: node_id}], _health} when is_binary(node_id) <- rows,
         {:ok, repo} <- TicketDetail.configured_repository(opts),
         {:ok, identity} <- TrackerIdentity.from_github(%{"node_id" => node_id, "number" => String.to_integer(id)}, repo, repo) do
      {:ok, identity}
    else
      {:error, _reason} -> {:error, :identity_lookup_unavailable}
      _ -> missing(snapshot)
    end
  end

  defp missing(%{status: status, truncated?: truncated}) when status in [:unavailable, :stale, :loading] or truncated,
    do: {:error, :open_tickets_unavailable}

  defp missing(_snapshot), do: :no_identity
end
