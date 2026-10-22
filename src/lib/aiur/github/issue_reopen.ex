defmodule Aiur.GitHub.IssueReopen do
  @moduledoc """
  Reopens a GitHub issue. State writes refuse to put an active label on a
  closed issue, so a ticket GitHub auto-closed must be reopened first (#4528).
  """

  alias Aiur.GitHub.{Errors, Transport, WriteThrough}

  @spec reopen(String.t(), keyword()) :: :ok | {:error, term()}
  def reopen(issue_number, opts \\ []) when is_binary(issue_number) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}"

      case request_fun.(%{method: :patch, url: url, token: token, body: %{"state" => "open"}}) do
        {:ok, %{status: status, body: issue}} when status in 200..299 and is_map(issue) ->
          WriteThrough.issue(issue)
          :ok

        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: _status} = response} ->
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    end
  end
end
