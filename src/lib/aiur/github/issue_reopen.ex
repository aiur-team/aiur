defmodule Aiur.GitHub.IssueReopen do
  @moduledoc """
  Reopens a GitHub issue. State writes refuse to put an active label on a
  closed issue, so a ticket GitHub auto-closed must be reopened first (#4528).
  """

  alias Aiur.GitHub.{Access, WriteThrough}

  @spec reopen(String.t(), keyword()) :: :ok | {:error, term()}
  def reopen(issue_number, opts \\ []) when is_binary(issue_number) do
    with {:ok, {owner, repo}} <- Access.parse_repo(),
         {:ok, token} <- Access.require_token() do
      request_fun = Keyword.get(opts, :request_fun, &Access.default_request_fun/1)
      url = "#{Access.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}"

      case request_fun.(%{method: :patch, url: url, token: token, body: %{"state" => "open"}}) do
        {:ok, %{status: status, body: issue}} when status in 200..299 and is_map(issue) ->
          WriteThrough.issue(issue)
          :ok

        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: _status} = response} ->
          {:error, Access.github_status_error(response)}

        {:error, reason} ->
          {:error, Access.classify_error({:error, reason})}
      end
    end
  end
end
