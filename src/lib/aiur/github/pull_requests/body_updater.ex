defmodule Aiur.GitHub.PullRequests.BodyUpdater do
  @moduledoc false

  alias Aiur.GitHub.{Errors, Transport, WriteThrough}

  @doc "Updates an open pull request body through the daemon's authenticated transport."
  @spec update_body(pos_integer(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_body(number, body, opts) when is_integer(number) and number > 0 and is_binary(body) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls/#{number}"

      case request_fun.(%{
             method: :patch,
             url: url,
             token: token,
             body: %{"body" => body},
             caller: "agent_handoff_body"
           }) do
        {:ok, %{status: status, body: response}} when status in 200..299 and is_map(response) ->
          WriteThrough.pull_request(response)
          {:ok, response}

        {:ok, response} ->
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    end
  end
end
