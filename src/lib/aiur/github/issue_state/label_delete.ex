defmodule Aiur.GitHub.IssueState.LabelDelete do
  @moduledoc false

  alias Aiur.GitHub.{Errors, Transport, WriteThrough}

  @spec delete(function(), String.t(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def delete(request_fun, token, owner, repo, issue_number, label, opts) do
    url =
      "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}/labels/#{URI.encode(label)}"

    case request_fun.(%{method: :delete, url: url, token: token}) do
      {:ok, %{status: status, body: labels}} when status in [200, 204] ->
        WriteThrough.issue_labels(issue_number, labels)
        verify_labels(labels, request_fun, token, owner, repo, issue_number, opts)

      {:ok, %{status: status}} when status in [200, 204, 404] ->
        verify_labels(nil, request_fun, token, owner, repo, issue_number, opts)

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp verify_labels(labels, _request_fun, _token, _owner, _repo, _issue_number, opts) when is_list(labels) do
    case Keyword.get(opts, :on_labels) do
      callback when is_function(callback, 1) ->
        callback.(Enum.map(labels, &Map.get(&1, "name", "")))

      _ ->
        :ok
    end
  end

  defp verify_labels(_labels, request_fun, token, owner, repo, issue_number, opts) do
    case Keyword.get(opts, :on_labels) do
      callback when is_function(callback, 1) ->
        url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}"

        case request_fun.(%{method: :get, url: url, token: token}) do
          {:ok, %{status: 200, body: %{"labels" => labels}}} when is_list(labels) ->
            WriteThrough.issue_labels(issue_number, labels)
            callback.(Enum.map(labels, &Map.get(&1, "name", "")))

          {:ok, %{status: _status} = response} ->
            {:error, {:state_label_verification_failed, Errors.github_status_error(response)}}

          {:error, reason} ->
            {:error, {:state_label_verification_failed, Errors.classify_error({:error, reason})}}
        end

      _ ->
        :ok
    end
  end
end
