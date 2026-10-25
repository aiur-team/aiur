defmodule Aiur.GitHub.IssueState.LabelAdd do
  @moduledoc false

  alias Aiur.GitHub.{Errors, Transport, WriteThrough}

  @spec add(function(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def add(request_fun, token, owner, repo, issue_number, label) do
    url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}/labels"

    case request_fun.(%{method: :post, url: url, token: token, body: %{"labels" => [label]}}) do
      {:ok, %{status: status, body: labels}} when status in [200, 201] ->
        WriteThrough.issue_labels(issue_number, labels)
        :ok

      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end
end
