defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub REST API client for issue tracking via labels.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @base_url "https://api.github.com"

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts \\ []) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      prefix = Config.github_label_prefix()
      labels = "#{prefix}:todo,#{prefix}:in-progress"
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      url = "#{@base_url}/repos/#{owner}/#{repo}/issues?labels=#{URI.encode(labels)}&state=open&per_page=100"

      do_list_issues(request_fun, url, token, owner, repo, prefix)
    end
  end

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, opts \\ []) when is_list(state_names) do
    if state_names == [], do: {:ok, []}, else: do_fetch_issues_by_states(state_names, opts)
  end

  @spec fetch_issue_states_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, opts \\ []) when is_list(issue_ids) do
    if issue_ids == [], do: {:ok, []}, else: do_fetch_issue_states_by_ids(issue_ids, opts)
  end

  @spec create_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_comment(issue_number, body, opts \\ []) when is_binary(issue_number) and is_binary(body) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}/comments"

      case request_fun.(%{method: :post, url: url, token: token, body: %{"body" => body}}) do
        {:ok, %{status: status}} when status in [200, 201] ->
          :ok

        {:ok, %{status: status}} ->
          Logger.error("GitHub create_comment failed status=#{status}")
          {:error, {:github_api_status, status}}

        {:error, reason} ->
          {:error, {:github_api_request, reason}}
      end
    end
  end

  @spec update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_issue_state(issue_number, state_name, opts \\ [])
      when is_binary(issue_number) and is_binary(state_name) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      prefix = Config.github_label_prefix()
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      issue_url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}"

      do_update_issue_state(request_fun, token, issue_url, owner, repo, issue_number, prefix, state_name)
    end
  end

  # -- Private helpers --------------------------------------------------------

  defp do_fetch_issues_by_states(state_names, opts) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      prefix = Config.github_label_prefix()
      labels = Enum.map_join(state_names, ",", &"#{prefix}:#{normalize_state(&1)}")
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
      url = "#{@base_url}/repos/#{owner}/#{repo}/issues?labels=#{URI.encode(labels)}&state=open&per_page=100"

      do_list_issues(request_fun, url, token, owner, repo, prefix)
    end
  end

  defp do_fetch_issue_states_by_ids(issue_ids, opts) do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, token} <- require_token() do
      prefix = Config.github_label_prefix()
      request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)

      do_fetch_issues_by_id_list(issue_ids, request_fun, token, owner, repo, prefix)
    end
  end

  defp do_list_issues(request_fun, url, token, owner, repo, prefix) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, Enum.map(body, &normalize_issue(&1, owner, repo, prefix))}

      {:ok, %{status: status}} ->
        Logger.error("GitHub API request failed status=#{status}")
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        Logger.error("GitHub API request failed: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  defp do_fetch_issues_by_id_list(issue_ids, request_fun, token, owner, repo, prefix) do
    result =
      Enum.reduce_while(issue_ids, {:ok, []}, fn issue_id, {:ok, acc} ->
        url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_id}"
        reduce_fetch_issue(request_fun, url, token, owner, repo, prefix, acc)
      end)

    case result do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  defp reduce_fetch_issue(request_fun, url, token, owner, repo, prefix, acc) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:cont, {:ok, [normalize_issue(body, owner, repo, prefix) | acc]}}

      {:ok, %{status: 404}} ->
        {:cont, {:ok, acc}}

      {:ok, %{status: status}} ->
        {:halt, {:error, {:github_api_status, status}}}

      {:error, reason} ->
        {:halt, {:error, {:github_api_request, reason}}}
    end
  end

  defp do_update_issue_state(request_fun, token, issue_url, owner, repo, issue_number, prefix, state_name) do
    new_label = "#{prefix}:#{normalize_state(state_name)}"

    case request_fun.(%{method: :get, url: issue_url, token: token}) do
      {:ok, %{status: 200, body: issue_body}} ->
        swap_labels(request_fun, token, owner, repo, issue_number, issue_body, prefix, new_label)
        maybe_close_issue(request_fun, token, issue_url, state_name)
        :ok

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp swap_labels(request_fun, token, owner, repo, issue_number, issue_body, prefix, new_label) do
    issue_body
    |> Map.get("labels", [])
    |> Enum.map(&Map.get(&1, "name", ""))
    |> Enum.filter(&String.starts_with?(&1, "#{prefix}:"))
    |> Enum.each(fn label ->
      url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}/labels/#{URI.encode(label)}"
      request_fun.(%{method: :delete, url: url, token: token})
    end)

    add_url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}/labels"
    request_fun.(%{method: :post, url: add_url, token: token, body: %{"labels" => [new_label]}})
  end

  defp maybe_close_issue(request_fun, token, issue_url, state_name) do
    if normalize_state(state_name) in ["done", "cancelled"] do
      request_fun.(%{method: :patch, url: issue_url, token: token, body: %{"state" => "closed"}})
    end
  end

  defp normalize_issue(gh_issue, owner, repo, prefix) when is_map(gh_issue) do
    number = gh_issue["number"]
    labels = gh_issue["labels"] || []
    label_names = Enum.map(labels, &(&1["name"] || ""))

    %Issue{
      id: to_string(number),
      identifier: "#{owner}/#{repo}##{number}",
      title: gh_issue["title"],
      description: gh_issue["body"],
      priority: extract_priority(label_names),
      state: extract_state(label_names, prefix),
      branch_name: nil,
      url: gh_issue["html_url"],
      assignee_id: get_in(gh_issue, ["assignee", "login"]),
      labels: Enum.map(label_names, &String.downcase/1),
      assigned_to_worker: true,
      created_at: parse_datetime(gh_issue["created_at"]),
      updated_at: parse_datetime(gh_issue["updated_at"])
    }
  end

  defp extract_state(label_names, prefix) do
    prefix_colon = "#{prefix}:"

    Enum.find_value(label_names, fn name ->
      if String.starts_with?(name, prefix_colon) do
        String.replace_prefix(name, prefix_colon, "")
      end
    end)
  end

  defp extract_priority(label_names) do
    Enum.find_value(label_names, &parse_priority_label/1)
  end

  defp parse_priority_label(name) do
    case Regex.run(~r/^priority:(\d+)$/, name) do
      [_, n] -> parse_priority_int(n)
      _ -> nil
    end
  end

  defp parse_priority_int(n) do
    case Integer.parse(n) do
      {priority, _} -> priority
      :error -> nil
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp normalize_state(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
    |> String.replace(" ", "-")
  end

  defp parse_repo do
    case Config.github_repo() do
      nil ->
        {:error, :missing_github_repo}

      repo_string ->
        case String.split(repo_string, "/") do
          [owner, repo] -> {:ok, {owner, repo}}
          _ -> {:error, {:invalid_github_repo, repo_string}}
        end
    end
  end

  defp require_token do
    case Config.github_token() do
      nil -> {:error, :missing_github_token}
      token -> {:ok, token}
    end
  end

  defp default_request_fun(%{method: :get, url: url, token: token}) do
    Req.get(url, headers: github_headers(token), connect_options: [timeout: 30_000])
  end

  defp default_request_fun(%{method: :post, url: url, token: token, body: body}) do
    Req.post(url, headers: github_headers(token), json: body, connect_options: [timeout: 30_000])
  end

  defp default_request_fun(%{method: :patch, url: url, token: token, body: body}) do
    Req.patch(url, headers: github_headers(token), json: body, connect_options: [timeout: 30_000])
  end

  defp default_request_fun(%{method: :delete, url: url, token: token}) do
    Req.delete(url, headers: github_headers(token), connect_options: [timeout: 30_000])
  end

  defp github_headers(token) do
    [
      {"Authorization", "Bearer #{token}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", "2022-11-28"}
    ]
  end
end
