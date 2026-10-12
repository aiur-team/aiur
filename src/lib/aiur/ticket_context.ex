defmodule Aiur.TicketContext do
  @moduledoc "Startup specs for ticket details and history shared by every dashboard ticket dialog."

  alias Aiur.BuildOrder.{TicketDetailCoordinator, TicketHistoryProvider}

  @spec child_specs(:early | :late, keyword()) :: [{module(), keyword()}]
  def child_specs(phase, opts)

  def child_specs(:early, _opts), do: [{TicketDetailCoordinator, runtime_config?: true}]
  def child_specs(:late, _opts), do: [{TicketHistoryProvider, runtime_config?: true}]
end
