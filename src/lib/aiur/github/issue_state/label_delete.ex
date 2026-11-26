defmodule Aiur.GitHub.IssueState.LabelDelete do
  @moduledoc false

  alias Aiur.GitHub.{Access, WriteThrough}

  @spec delete(function(), String.t(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def delete(request_fun, token, owner, repo, issue_number, label, opts) do
    url =
      "#{Access.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}/labels/#{URI.encode(label)}"

    case request_fun.(%{method: :delete, url: url, token: token}) do
      {:ok, %{status: status, body: labels}} when status in [200, 204] ->
        WriteThrough.issue_labels(issue_number, labels)
        verify_labels(request_fun, token, owner, repo, issue_number, opts)

      {:ok, %{status: status}} when status in [200, 204, 404] ->
        verify_labels(request_fun, token, owner, repo, issue_number, opts)

      {:ok, %{status: _status} = response} ->
        {:error, Access.github_status_error(response)}

      {:error, reason} ->
        {:error, Access.classify_error({:error, reason})}
    end
  end

  defp verify_labels(request_fun, token, owner, repo, issue_number, opts) do
    case Keyword.get(opts, :on_labels) do
      callback when is_function(callback, 1) ->
        url = "#{Access.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}"

        case request_fun.(%{method: :get, url: url, token: token}) do
          {:ok, %{status: 200, body: %{"labels" => labels}}} when is_list(labels) ->
            WriteThrough.issue_labels(issue_number, labels)
            callback.(Enum.map(labels, &Map.get(&1, "name", "")))

          {:ok, %{status: _status} = response} ->
            {:error, {:state_label_verification_failed, Access.github_status_error(response)}}

          {:error, reason} ->
            {:error, {:state_label_verification_failed, Access.classify_error({:error, reason})}}
        end

      _ ->
        :ok
    end
  end
end
