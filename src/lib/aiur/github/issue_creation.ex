defmodule Aiur.GitHub.IssueCreation do
  @moduledoc false
  alias Aiur.GitHub.{Errors, Transport, WriteThrough}

  @spec create(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(%{title: title, body: body, labels: labels}, opts) when is_binary(title) and is_binary(body) and is_list(labels) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request = %{
        method: :post,
        url: "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues",
        token: token,
        caller: "experiment_analysis_create",
        body: %{"title" => title, "body" => body, "labels" => labels}
      }

      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      finish(request_fun.(request))
    end
  end

  def create(_attrs, _opts), do: {:error, :invalid_issue}

  defp finish({:ok, %{status: 201, body: %{"number" => number, "html_url" => url} = issue}}) when is_integer(number) and number > 0 and is_binary(url) do
    WriteThrough.issue(issue)
    {:ok, %{"number" => number, "url" => url}}
  end

  # An accepted write without identity is ambiguous; the caller must reconcile the nonce before retrying.
  defp finish({:ok, %{status: status}}) when status in [200, 201, 202], do: {:error, :outcome_unknown}
  defp finish({:ok, response}), do: {:error, Errors.github_status_error(response)}
  defp finish({:error, _reason} = error), do: error
end
