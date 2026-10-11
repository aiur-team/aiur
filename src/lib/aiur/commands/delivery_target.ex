defmodule Aiur.Commands.DeliveryTarget do
  @moduledoc """
  Port through which Commands deliver answers and read target ticket state.

  Commands must not depend on orchestration, so the implementation is bound by
  application config (`config :aiur, :commands_delivery_target, Module`) at the
  composition root and resolved per call.
  """

  # `server` is the caller's `:operator_messages` override; nil means the target's default.
  @callback send_correlated(server :: GenServer.server() | nil, ticket_identifier :: String.t(), payload :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback revalidate_issue(Aiur.Issue.t(), issue_fetcher :: function(), MapSet.t()) ::
              {:ok, Aiur.Issue.t()} | {:skip, :missing | Aiur.Issue.t()} | {:error, term()}
  @callback terminal_state_set() :: MapSet.t(String.t())
  @callback terminal_issue_state?(String.t() | term(), MapSet.t()) :: boolean()
  @callback active_identifiers() :: {:ok, [String.t()]} | {:error, term()}

  @spec impl() :: module()
  def impl, do: Application.get_env(:aiur, :commands_delivery_target, Aiur.Commands.DeliveryTarget.Unbound)
end
