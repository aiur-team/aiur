defmodule Aiur.GitHub.OptimisticFailure do
  @moduledoc "Fresh blocker evidence and idempotent parking writes for optimistic dependents."

  alias Aiur.GitHub.{AgentMarker, Comments, Errors, Transport}
  alias Aiur.GitHub.PullRequests.OpenPullRequests

  @spec optimistic_blocker(String.t() | integer(), integer() | nil, keyword()) :: {:ok, map() | nil} | {:error, term()}
  def optimistic_blocker(issue_id, pr_number, opts \\ []) do
    opts = attributed(opts, "optimistic_guard_read")

    with {:ok, recorded} <- recorded_pull_request(pr_number, opts),
         {:ok, replacement} <- OpenPullRequests.fetch_open_pull_request_for_branch(issue_id, opts),
         :ok <- validate_open_pull_request(replacement) do
      {:ok, replacement || recorded}
    end
  end

  @spec park_pull_request(String.t() | integer(), keyword()) :: :ok | {:error, term()}
  def park_pull_request(issue_id, opts \\ []) do
    with {:ok, pr} <- OpenPullRequests.fetch_open_pull_request_for_branch(issue_id, attributed(opts, "optimistic_guard_read")) do
      draft_pull_request(pr, attributed(opts, "optimistic_guard_draft"))
    end
  end

  @spec comment_optimistic_park(String.t() | integer(), String.t() | integer(), term(), keyword()) :: :ok | {:error, term()}
  def comment_optimistic_park(dependent, blocker, cause, opts \\ []) do
    opts = attributed(opts, "optimistic_guard_comment")
    marker = "<!-- optimistic-park:#{dependent}:#{blocker} -->"

    body =
      AgentMarker.stamp(
        "Optimistic work parked: blocker ##{blocker} failed (#{cause}). Branch and PR are retained. Wait for a replacement, re-base on the default branch and resume, or close.\n\n#{marker}"
      )

    with {:ok, comments} <- comments(dependent, opts) do
      if Enum.any?(comments, &String.contains?(Map.get(&1, "body") || "", marker)) do
        :ok
      else
        create_park_comment(dependent, body, opts)
      end
    end
  end

  defp create_park_comment(dependent, body, opts) do
    with :ok <- Comments.create_comment(to_string(dependent), body, opts),
         {:ok, comments} <- comments(dependent, opts) do
      if Enum.any?(comments, &(Map.get(&1, "body") == body)), do: :ok, else: {:error, :optimistic_park_comment_unverified}
    end
  end

  defp validate_open_pull_request(nil), do: :ok
  defp validate_open_pull_request(%{"number" => number, "state" => "open"}) when is_integer(number) and number > 0, do: :ok
  defp validate_open_pull_request(_pr), do: {:error, :optimistic_blocker_pr_unreadable}

  defp recorded_pull_request(nil, _opts), do: {:ok, nil}

  defp recorded_pull_request(number, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, body} <- request(%{method: :get, url: "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls/#{number}", token: token}, opts) do
      case body do
        %{"state" => state, "merged" => merged} when state in ["open", "closed"] and is_boolean(merged) -> {:ok, body}
        _ -> {:error, :optimistic_blocker_pr_unreadable}
      end
    end
  end

  defp draft_pull_request(nil, _opts), do: :ok
  defp draft_pull_request(%{"draft" => true}, _opts), do: :ok

  defp draft_pull_request(%{"draft" => false, "node_id" => node_id}, opts) when is_binary(node_id) and node_id != "" do
    query = "mutation($id: ID!) { convertPullRequestToDraft(input: {pullRequestId: $id}) { pullRequest { isDraft } } }"

    with {:ok, token} <- Transport.require_token(opts),
         {:ok, response} <- request(%{method: :post, url: Transport.graphql_url(), token: token, body: %{"query" => query, "variables" => %{"id" => node_id}}}, opts) do
      case response do
        %{"data" => %{"convertPullRequestToDraft" => %{"pullRequest" => %{"isDraft" => true}}}} -> :ok
        _ -> {:error, :optimistic_park_draft_unverified}
      end
    end
  end

  defp draft_pull_request(_pr, _opts), do: {:error, :optimistic_park_pr_unreadable}

  defp comments(issue_id, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_id}/comments?per_page=100"
      Comments.fetch_repo_comment_stream(Keyword.fetch!(opts, :request_fun), token, url, [])
    end
  end

  defp request(request, opts) do
    case Keyword.fetch!(opts, :request_fun).(request) do
      {:ok, %{status: status, body: body}} when status in [200, 201] -> {:ok, body}
      {:ok, response} -> {:error, Errors.github_status_error(response)}
      {:error, reason} -> {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp attributed(opts, caller) do
    request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
    Keyword.put(opts, :request_fun, fn request -> request_fun.(Map.put(request, :caller, caller)) end)
  end
end
