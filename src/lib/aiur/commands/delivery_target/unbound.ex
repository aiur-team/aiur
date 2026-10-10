defmodule Aiur.Commands.DeliveryTarget.Unbound do
  @moduledoc """
  Delivery target used when no composition bound one.

  Every failure names its own cause (`:delivery_target_unbound`) so a missing
  binding is never reported as an orchestrator outage.
  """

  @behaviour Aiur.Commands.DeliveryTarget

  @impl true
  def send_correlated(_server, _ticket_identifier, _payload), do: {:error, :delivery_target_unbound}

  @impl true
  def revalidate_issue(_issue, _issue_fetcher, _terminal_states), do: {:error, :delivery_target_unbound}

  @impl true
  def terminal_state_set, do: MapSet.new()

  @impl true
  def terminal_issue_state?(_state_name, _terminal_states), do: false

  @impl true
  def active_identifiers, do: {:error, :delivery_target_unbound}
end
