defmodule Aiur.MainWatch.FixerGitHub do
  @moduledoc false
  alias Aiur.GitHub.{Client, Errors, MainFixer, PullRequests, Transport}

  @spec open(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def open(label, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(), {:ok, token} <- Transport.require_token(opts) do
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues?state=open&labels=#{URI.encode_www_form(label)}&per_page=100"
      with {:ok, issues} <- pages(url, token, opts, 1, []), do: evidence(Enum.filter(issues, &(not is_nil(MainFixer.marker(&1["body"])))), opts)
    end
  end

  defp pages(url, token, opts, page, acc) when page <= 10 do
    case request(%{method: :get, url: url <> "&page=#{page}", token: token, caller: "main_fixer_open_issues", max_response_bytes: 16_777_216}, opts) do
      {:ok, %{status: 200, body: issues}} when is_list(issues) ->
        acc = acc ++ Enum.reject(issues, &Map.has_key?(&1, "pull_request"))
        if length(issues) < 100, do: {:ok, acc}, else: pages(url, token, opts, page + 1, acc)

      response ->
        error(response)
    end
  end

  defp pages(_url, _token, _opts, _page, _acc), do: {:error, :main_fixer_page_limit}

  defp evidence(issues, opts) do
    Enum.reduce_while(issues, {:ok, []}, fn issue, {:ok, acc} ->
      case comments(issue, opts) do
        {:ok, body} -> {:cont, {:ok, acc ++ [Map.put(issue, "body", body)]}}
        error -> {:halt, error}
      end
    end)
  end

  defp comments(%{"comments" => count} = issue, opts) when count > 0 do
    with {:ok, comments, _etag} <- Client.fetch_issue_comments_conditional(issue["number"], opts) do
      bodies = comments |> Enum.filter(&(not is_nil(MainFixer.marker(&1["body"])))) |> Enum.map(& &1["body"])
      {:ok, Enum.join([issue["body"] || "" | bodies], "\n")}
    end
  end

  defp comments(issue, _opts), do: {:ok, issue["body"] || ""}

  @spec create(map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate create(body, opts), to: MainFixer

  @spec comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def comment(id, body, opts), do: Client.create_comment(id, body, opts)

  @spec pr_open?(String.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def pr_open?(id, opts) do
    with {:ok, pr} <- PullRequests.fetch_open_pull_request_for_branch(id, opts) do
      {:ok, not is_nil(pr)}
    end
  end

  defp request(call, opts), do: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1).(call)
  defp error({:error, reason}), do: {:error, reason}
  defp error({:ok, response}), do: {:error, Errors.github_status_error(response)}
end
