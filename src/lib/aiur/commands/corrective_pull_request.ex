defmodule Aiur.Commands.CorrectivePullRequest do
  @moduledoc false
  alias Aiur.Commands.DeliveryTarget
  alias Aiur.Tracker

  @spec read(String.t(), keyword()) :: Aiur.Tracker.ticket_pull_request_result()
  def read(identifier, opts) do
    case Keyword.get(opts, :pull_request, &Tracker.ticket_pull_request/1).(identifier) do
      {:ok, nil} -> resolve_closed(identifier, opts)
      {:ok, %{merged?: true, merge_commit_sha: sha}} = result when is_binary(sha) and sha != "" -> result
      {:ok, %{merged?: true}} -> resolve_closed(identifier, opts)
      result -> result
    end
  end

  defp resolve_closed(identifier, opts) do
    case Keyword.get(opts, :issues, &Tracker.fetch_issue_states_by_ids/1).([identifier]) do
      {:ok, [issue]} ->
        target = DeliveryTarget.impl()

        if target.terminal_issue_state?(issue.state, target.terminal_state_set()),
          do: Keyword.get(opts, :resolve_pull_request, &Tracker.resolve_ticket_pull_request/2).(identifier, caller: "command_override_merged_pr"),
          else: {:ok, nil}

      {:ok, _missing} ->
        {:error, :original_ticket_missing}

      {:error, _reason} = error ->
        error
    end
  end
end
