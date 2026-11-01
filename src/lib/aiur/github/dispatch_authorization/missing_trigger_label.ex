defmodule Aiur.GitHub.DispatchAuthorization.MissingTriggerLabel do
  @moduledoc false

  alias Aiur.GitHub.{Access, Config, Issues}
  alias Aiur.Issue

  @spec recheck(Issue.t(), String.t(), String.t(), keyword()) :: {:ok, Issue.t()} | {:error, :missing_trigger_label}
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

      {:error, _reason} ->
        {:error, :missing_trigger_label}
    end
  end
end
