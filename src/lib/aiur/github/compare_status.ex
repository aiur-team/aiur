defmodule Aiur.GitHub.CompareStatus do
  @moduledoc "Compare status of one commit against another via the GitHub compare API."
  alias Aiur.GitHub.{Errors, Transport}

  @doc "Compare status of `head` against `base` (`ahead`, `identical`, `behind`, `diverged`)."
  @spec fetch(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def fetch(base_sha, head_sha, opts \\ [])
      when is_binary(base_sha) and is_binary(head_sha) and base_sha != "" and head_sha != "" do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/compare/#{base_sha}...#{head_sha}?per_page=1"

      case request_fun.(%{method: :get, url: url, token: token}) do
        {:ok, %{status: 200, body: %{"status" => status}}} when is_binary(status) -> {:ok, status}
        {:ok, %{status: _status} = response} -> {:error, Errors.github_status_error(response)}
        {:error, reason} -> {:error, Errors.classify_error({:error, reason})}
      end
    end
  end
end
