defmodule Aiur.Alerts.StaleNotClosed do
  @moduledoc """
  Resolves false "ticket was not closed" (`merge_terminal_write_failed`) and
  "merge attribution could not be determined" (`attribution_check_failed`)
  attentions for tickets that are in fact closed `done` (#3943).
  """

  alias Aiur.{AlertFeed, Alerts}
  alias Aiur.GitHub.Issues, as: GitHubIssues

  # "ticket was not closed" and "merge attribution could not be determined"
  @suffixes [".agent.attention.merge_terminal_write_failed", ".merge.attribution_check_failed"]

  @doc "Resolves the open alert for one ticket, if any. Safe to call when none is open."
  @spec resolve(String.t() | integer(), keyword()) :: :ok
  def resolve(identifier, opts \\ []) do
    identifier = to_string(identifier)
    open = open_topics(opts)

    for suffix <- @suffixes, topic = "ticket.#{identifier}#{suffix}", topic in open do
      emit_resolved(identifier, topic, opts)
    end

    :ok
  end

  @doc "Pipe helper for a `done` state write: resolves on `:ok`, returns the write result unchanged."
  @spec resolve_on_ok(term(), String.t() | integer()) :: term()
  def resolve_on_ok(:ok = result, identifier) do
    resolve(identifier)
    result
  end

  def resolve_on_ok(result, _identifier), do: result

  @doc """
  Resolves every open alert whose ticket `done?` reports closed. `done?` takes
  the list of identifiers with an open alert and returns the done subset.
  """
  @spec reconcile(([String.t()] -> [String.t()]), keyword()) :: :ok
  def reconcile(done_fun, opts \\ []) when is_function(done_fun, 1) do
    open = open_topics(opts)

    open
    |> Enum.map(&ticket_of/1)
    |> Enum.uniq()
    |> done_fun.()
    |> Enum.each(&resolve(&1, opts))

    :ok
  end

  @doc "Returns the subset of `ids` whose GitHub issue is labelled done."
  @spec done_ids([String.t()]) :: [String.t()]
  def done_ids(ids) do
    case GitHubIssues.fetch_issue_states_by_ids(ids) do
      {:ok, issues} -> for issue <- issues, done?(issue.state), do: issue.identifier
      _error -> []
    end
  end

  defp done?(state), do: String.downcase(to_string(state)) == "done"

  defp open_topics(opts) do
    [{:needs_attention, true} | opts]
    |> AlertFeed.list()
    |> Enum.map(& &1["topic"])
    |> Enum.filter(fn topic -> Enum.any?(@suffixes, &String.ends_with?(topic || "", &1)) end)
    |> Enum.uniq()
  end

  defp ticket_of("ticket." <> rest), do: rest |> String.split(".", parts: 2) |> hd()

  defp emit_resolved(identifier, topic, opts) do
    alert_fun = Keyword.get(opts, :alert_fun, &Alerts.emit_custom/3)

    alert_fun.(
      topic <> ".resolved",
      "Ticket #{identifier} is closed done; the earlier merge alert was false.",
      issue: identifier,
      reason: "The ticket is observed closed with agent:done.",
      needs_attention: false,
      severity: "info",
      central: true
    )
  end
end
