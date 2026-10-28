defmodule Aiur.Commands.OverrideContext do
  @moduledoc "Resolves override routing observations before entering DecisionStore."

  alias Aiur.Commands.DeliveryTarget

  @unknown %{pr: :unknown, worker: :unknown, capacity: :unknown}

  @spec options(String.t() | nil, keyword()) :: keyword()
  def options(ticket_identifier, opts) do
    Keyword.put_new_lazy(opts, :override_context, fn -> resolve(ticket_identifier) end)
  end

  defp resolve(ticket_identifier) do
    target = DeliveryTarget.impl()

    if Code.ensure_loaded?(target) and function_exported?(target, :override_context, 1),
      do: target.override_context(ticket_identifier),
      else: @unknown
  end
end
