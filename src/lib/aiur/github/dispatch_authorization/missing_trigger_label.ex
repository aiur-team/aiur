defmodule Aiur.GitHub.DispatchAuthorization.MissingTriggerLabel do
  @moduledoc false

  alias Aiur.GitHub.{Access, Config, Issues}
  alias Aiur.Issue

  @spec recheck(Issue.t(), String.t(), String.t(), keyword()) ::
          {:ok, Issue.t()} | {:error, :missing_trigger_label | {:fetch_failed, term()}}
  def recheck(%Issue{} = issue, owner, repo, opts) do
    read_opts = [
      token: Keyword.get(opts, :token, Config.token()),
      request_fun: Keyword.get(opts, :request_fun, &Access.default_request_fun/1),
      unconditional: true,
      caller: "dispatch_authorization_missing_trigger_label",
      repository: {owner, repo}
    ]

    case Issues.fetch_issue_raw_conditional(issue.id, read_opts) do
      {:ok, body, _outcome} ->
        labels = Enum.map(body["labels"] || [], &Map.get(&1, "name", ""))
        prefix = Keyword.get(opts, :label_prefix, Config.label_prefix())
        state = Issues.extract_state(body, labels, prefix)

        if is_binary(state) and state != "" do
          {:ok, %{issue | state: state, state_labels: Issues.extract_state_labels(labels, prefix)}}
        else
          {:error, :missing_trigger_label}
        end

      {:error, reason} ->
        {:error, {:fetch_failed, reason}}
    end
  end

  @spec deferred_reason(term()) :: term()
  def deferred_reason(:missing_trigger_label), do: :missing_trigger_label
  def deferred_reason({:fetch_failed, reason}), do: {:missing_trigger_label_fetch, reason}

  @spec alert_message(term()) :: {String.t(), String.t()}
  def alert_message(:missing_trigger_label) do
    {"issue had no agent:* state label at dispatch time; dispatch will retry on the next poll. " <>
       "Re-apply the state label with `aiur --todo <n>`.",
     "Issue had no agent:* state label at dispatch time after one fresh re-fetch. " <>
       "Re-apply the state label with `aiur --todo <n>`; dispatch retries on the next poll."}
  end

  def alert_message(reason) do
    {"label provenance could not be verified (#{inspect(reason)}).", "GitHub dispatch authorization requires verified trigger-label provenance: #{inspect(reason)}"}
  end
end
