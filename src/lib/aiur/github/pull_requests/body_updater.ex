defmodule Aiur.GitHub.PullRequests.BodyUpdater do
  @moduledoc false

  alias Aiur.GitHub.{Access, WriteThrough}

  @doc "Updates an open pull request body through the daemon's authenticated transport."
  @spec update_body(pos_integer(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_body(number, body, opts) when is_integer(number) and number > 0 and is_binary(body) do
    with {:ok, {owner, repo}} <- Access.parse_repo(),
         {:ok, token} <- Access.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Access.default_request_fun/1)
      url = "#{Access.base_url()}/repos/#{owner}/#{repo}/pulls/#{number}"

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
          {:error, Access.github_status_error(response)}

        {:error, reason} ->
          {:error, Access.classify_error({:error, reason})}
      end
    end
  end
end
