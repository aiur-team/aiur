defmodule Aiur.TicketMarkers do
  @moduledoc "Public marker-write boundary backed by the ticket transition owner."

  @spec write(String.t(), :add | :remove, String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate write(issue_id, action, label, opts), to: Aiur.Orchestrator.TicketTransition, as: :write_marker
end
