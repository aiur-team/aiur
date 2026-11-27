defmodule Aiur.DecisionStore.OptionalDefaults do
  @moduledoc false

  @spec apply(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def apply(ticket_identifier, server \\ Aiur.DecisionStore),
    do: GenServer.call(server, {:apply_optional_command_defaults, ticket_identifier}, 5_000)
end
