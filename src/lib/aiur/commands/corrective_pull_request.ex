defmodule Aiur.Commands.CorrectivePullRequest do
  @moduledoc false
  alias Aiur.Tracker

  @closure_freshness_ms 300_000

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
    case Keyword.get(opts, :issue_closure, &Tracker.issue_closure/2).(identifier, @closure_freshness_ms) do
      {:ok, %{open?: false}} ->
        Keyword.get(opts, :resolve_pull_request, &Tracker.resolve_ticket_pull_request/2).(identifier, caller: "command_override_merged_pr")

      {:ok, %{open?: true}} ->
        {:ok, nil}

      {:error, :unsupported} ->
        {:ok, nil}

      {:error, _reason} = error ->
        error
    end
  end
end
