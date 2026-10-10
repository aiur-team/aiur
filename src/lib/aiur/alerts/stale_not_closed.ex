defmodule Aiur.Alerts.StaleNotClosed do
  @moduledoc """
  Resolves `merge_terminal_write_failed` ("ticket was not closed") attentions
  for tickets that are in fact closed `done` (#3943).
  """

  alias Aiur.{AlertFeed, Alerts}

  @slug "merge_terminal_write_failed"

  @doc "Resolves the open alert for one ticket, if any. Safe to call when none is open."
  @spec resolve(String.t() | integer(), keyword()) :: :ok
  def resolve(identifier, opts \\ []) do
    identifier = to_string(identifier)
    topic = "ticket.#{identifier}.agent.attention.#{@slug}"

    if topic in open_topics(opts), do: emit_resolved(identifier, topic, opts)

    :ok
  end

  @doc """
  Resolves every open alert whose ticket `done?` reports closed. `done?` takes
  the list of identifiers with an open alert and returns the done subset.
  """
  @spec reconcile(([String.t()] -> [String.t()]), keyword()) :: :ok
  def reconcile(done_fun, opts \\ []) when is_function(done_fun, 1) do
    open = open_topics(opts)

    open
    |> Enum.map(&ticket_of/1)
    |> done_fun.()
    |> Enum.each(&resolve(&1, opts))

    :ok
  end

  @doc "Returns the subset of `ids` whose GitHub issue is labelled done."
  @spec done_ids([String.t()]) :: [String.t()]
  def done_ids(ids) do
    case Aiur.GitHub.Issues.fetch_issue_states_by_ids(ids) do
      {:ok, issues} -> for issue <- issues, done?(issue.state), do: issue.identifier
      _error -> []
    end
  end

  defp done?(state), do: String.downcase(to_string(state)) == "done"

  defp open_topics(opts) do
    [{:needs_attention, true} | opts]
    |> AlertFeed.list()
    |> Enum.map(& &1["topic"])
    |> Enum.filter(&String.ends_with?(&1 || "", ".agent.attention." <> @slug))
    |> Enum.uniq()
  end

  defp ticket_of("ticket." <> rest), do: rest |> String.split(".", parts: 2) |> hd()

  defp emit_resolved(identifier, topic, opts) do
    alert_fun = Keyword.get(opts, :alert_fun, &Alerts.emit_custom/3)

    alert_fun.(
      topic <> ".resolved",
      "Ticket #{identifier} is closed done; the earlier \"ticket was not closed\" alert was false.",
      issue: identifier,
      reason: "The ticket is observed closed with agent:done.",
      needs_attention: false,
      severity: "info",
      central: true
    )
  end
end
