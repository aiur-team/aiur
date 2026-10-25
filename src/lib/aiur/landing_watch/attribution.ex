defmodule Aiur.LandingWatch.Attribution do
  @moduledoc "Checks current PR commits for AI co-author trailers before queueing."

  alias Aiur.GitHub.{Errors, Transport}

  @max_pages 100

  @spec clean?(String.t()) :: boolean()
  def clean?(message) when is_binary(message) do
    not Regex.match?(~r/^co-authored-by:.*(claude|anthropic|codex|openai|chatgpt|copilot|gemini|cursor|opencode|deepseek|kimi)/im, message) and
      not Regex.match?(~r/🤖|Generated with \[?(Claude|Codex|OpenCode)/i, message)
  end

  def clean?(_), do: false

  @spec pull_request_clean?(pos_integer(), keyword()) :: {:ok, :clean | {:ai_attribution, String.t()}} | {:error, term()}
  def pull_request_clean?(number, opts \\ [])

  def pull_request_clean?(number, opts) when is_integer(number) and number > 0 do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/pulls/#{number}/commits?per_page=100"
      read_commits(request_fun, token, url, 0)
    end
  end

  def pull_request_clean?(_, _), do: {:error, :invalid_pull_request_number}

  defp read_commits(_request_fun, _token, _url, @max_pages), do: {:error, :pull_request_commit_list_too_large}

  defp read_commits(request_fun, token, url, page) do
    case request_fun.(%{method: :get, url: url, token: token, caller: "landing_watch_commits"}) do
      {:ok, %{status: 200, body: commits} = response} when is_list(commits) and commits != [] ->
        consume_page(commits, response, request_fun, token, page)

      {:ok, %{status: 200, body: []}} ->
        {:error, :pull_request_has_no_commits}

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp consume_page(commits, response, request_fun, token, page) do
    messages = Enum.map(commits, &get_in(&1, ["commit", "message"]))

    if Enum.any?(messages, &(not is_binary(&1))) do
      {:error, :invalid_pull_request_commit}
    else
      case attribution_result(messages) do
        {:ok, :clean} -> follow_page(response, request_fun, token, page)
        result -> result
      end
    end
  end

  defp follow_page(response, request_fun, token, page) do
    case Transport.parse_next_page_url(Map.get(response, :headers, [])) do
      nil -> {:ok, :clean}
      next -> read_commits(request_fun, token, next, page + 1)
    end
  end

  defp attribution_result(messages) do
    case Enum.find(messages, &(not clean?(&1))) do
      nil -> {:ok, :clean}
      message -> {:ok, {:ai_attribution, attribution_detail(message)}}
    end
  end

  defp attribution_detail(message) do
    message
    |> String.split("\n")
    |> Enum.find(fn line -> Regex.match?(~r/^co-authored-by:|🤖|Generated with/i, line) end)
    |> case do
      nil -> "AI attribution marker found in commit message"
      line -> String.slice(line, 0, 180)
    end
  end
end
