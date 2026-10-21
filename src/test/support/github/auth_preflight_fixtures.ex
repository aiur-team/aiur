defmodule Aiur.GitHub.AuthPreflight.TestFixtures do
  @moduledoc false

  @token_cache_key {Aiur.GitHub.Access.Token, :resolved_token}

  def counting_request_fun(counter, response_fun) do
    fn request ->
      Agent.update(counter, &(&1 + 1))
      response_fun.(request)
    end
  end

  def start_counter do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    counter
  end

  def count(counter), do: Agent.get(counter, & &1)

  def ok_response(_request),
    do: {:ok, %{status: 200, headers: [{"x-ratelimit-remaining", "42"}], body: %{}}}

  # An ordinary, non-preflight tracker request carrying the proven credential.
  def request do
    %{method: :get, url: "https://api.github.com/repos/owner/repo/issues", token: "preflight-token"}
  end

  def unauthorized,
    do: {:ok, %{status: 401, headers: [], body: %{"message" => "Bad credentials"}}}

  def put_or_delete(key, nil), do: Application.delete_env(:aiur, key)
  def put_or_delete(key, value), do: Application.put_env(:aiur, key, value)

  def put_token(token) do
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", token)
  end
end
