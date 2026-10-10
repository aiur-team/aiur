defmodule Aiur.Orchestrator.CommandDeliveryTarget do
  @moduledoc """
  Orchestration's implementation of `Aiur.Commands.DeliveryTarget`.

  The only orchestration entry point for Commands: answers go to the worker
  running the ticket through `OperatorMessages`, and target state is read from
  the dispatch policy. Bound in `config/config.exs`.
  """

  @behaviour Aiur.Commands.DeliveryTarget

  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, OperatorMessages}

  @active_identifiers_timeout 1_000

  @impl true
  def send_correlated(ticket_identifier, payload),
    do: OperatorMessages.send_correlated_operator_message(Aiur.Orchestrator, ticket_identifier, payload)

  @impl true
  def revalidate_issue(issue, issue_fetcher, terminal_states),
    do: Dispatcher.revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_states)

  @impl true
  def terminal_state_set, do: DispatchPolicy.terminal_state_set()

  @impl true
  def terminal_issue_state?(state_name, terminal_states),
    do: DispatchPolicy.terminal_issue_state?(state_name, terminal_states)

  @impl true
  def active_identifiers do
    {:ok, GenServer.call(Aiur.Orchestrator, :list_active_identifiers, @active_identifiers_timeout)}
  catch
    :exit, reason -> {:error, {:orchestrator_unavailable, reason}}
  end
end
