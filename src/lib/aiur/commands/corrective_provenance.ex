defmodule Aiur.Commands.CorrectiveProvenance do
  @moduledoc false

  alias Aiur.Commands.CorrectiveTicketBody
  alias Aiur.{DecisionStore, Issue}

  @spec check(Issue.t(), GenServer.server()) :: boolean()
  def check(issue, store \\ DecisionStore) do
    authorized?(issue, DecisionStore.list(store))
  catch
    :exit, _unavailable -> false
  end

  # The tracker separately verifies the daemon creator and every state-label actor.
  @spec authorized?(Issue.t(), [Aiur.Decision.t()]) :: boolean()
  def authorized?(%Issue{description: body, url: url} = issue, decisions) when is_binary(body) and is_binary(url) do
    Enum.any?(decisions, fn decision -> Enum.any?(decision.overrides, &linked?(issue, &1)) end)
  end

  def authorized?(_issue, _decisions), do: false

  defp linked?(issue, %{action_id: action, corrective_ticket: %{identifier: identifier, url: url}}) when is_binary(url) do
    marker = CorrectiveTicketBody.marker(action)
    issue.id == identifier and issue.url == url and length(:binary.matches(issue.description, marker)) == 1
  end

  defp linked?(_issue, _record), do: false
end
