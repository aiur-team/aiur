defmodule Aiur.Init.GitHub do
  @moduledoc """
  GitHub API adapters for the `aiur init` wizard — label management, login
  detection, and repo detection. All network calls are isolated here so the
  rest of the wizard stays pure and testable.
  """

  alias Aiur.Codeowners.Edit
  alias Aiur.GitHub.BotIdentity
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.Labels
  alias Aiur.GitHub.Transport

  @config_file_name ".aiur/config"
  @env_file_name ".env"
  @token_url "https://github.com/settings/tokens"

  @spec create_labels(map(), [String.t()]) :: :ok | {:error, String.t()}
  def create_labels(%{kind: "github", repo: repo}, labels) do
    with {:ok, {owner, name}} <- parse_owner_repo(repo),
         {:ok, token} <- require_github_token() do
      case Labels.ensure(owner, name, token, labels) do
        :ok -> :ok
        {:error, reason} -> {:error, label_error_message(reason)}
      end
    end
  end

  def create_labels(_tracker, _labels), do: :ok

  @spec list_repo_labels(map()) :: {:ok, [String.t()]} | {:error, term()}
  def list_repo_labels(%{kind: "github", repo: repo}) do
    with {:ok, {owner, name}} <- parse_owner_repo(repo),
         {:ok, token} <- require_github_token() do
      fetch_label_names(owner, name, token, 1, [])
    end
  end

  def list_repo_labels(_tracker), do: {:ok, []}

  @doc false
  @spec fetch_label_names(String.t(), String.t(), String.t(), pos_integer(), [String.t()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def fetch_label_names(owner, name, token, page, acc) do
    url = "https://api.github.com/repos/#{owner}/#{name}/labels?per_page=100&page=#{page}"

    headers = [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"user-agent", "aiur-init"}
    ]

    case Req.get(url, headers: headers, connect_options: [timeout: 30_000]) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        names = acc ++ Enum.map(body, & &1["name"])
        if length(body) == 100, do: fetch_label_names(owner, name, token, page + 1, names), else: {:ok, names}

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  rescue
    error -> {:error, {:github_api_request, Exception.message(error)}}
  end

  @doc false
  @spec parse_owner_repo(String.t() | nil) :: {:ok, {String.t(), String.t()}} | {:error, String.t()}
  def parse_owner_repo(repo) do
    case repo && String.split(to_string(repo), "/", trim: true) do
      [owner, name] -> {:ok, {owner, name}}
      _ -> {:error, "github.repo is not set to owner/name — add it to #{@config_file_name}"}
    end
  end

  @doc false
  @spec require_github_token() :: {:ok, String.t()} | {:error, String.t()}
  def require_github_token do
    case GitHubConfig.token() do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, "GITHUB_TOKEN not set — add it to #{@env_file_name} (#{@token_url})"}
    end
  end

  @doc false
  @spec label_error_message(term()) :: String.t()
  def label_error_message({:github_api_status, 403, label}),
    do: "GitHub rejected #{label} (403) — the token needs repo write scope"

  def label_error_message({:github_api_status, 404, label}),
    do:
      "GitHub returned 404 for #{label} — the repo wasn't found or the token can't access it. " <>
        "Check github.repo in #{@config_file_name} and that the token's account has access to this repo (Issues: Read & write)."

  def label_error_message({:github_api_status, status, label}),
    do: "GitHub rejected #{label} (HTTP #{status})"

  def label_error_message({:github_api_request, reason}),
    do: "request failed: #{inspect(reason)}"

  def label_error_message(other), do: inspect(other)

  @spec detect_github_login() :: String.t() | nil
  def detect_github_login do
    case System.cmd("gh", ["api", "user", "--jq", ".login"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> Edit.normalize_login()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Resolves the GitHub login that the configured `GITHUB_TOKEN` authenticates as,
  via the validated viewer-identity path. This is the login `aiur init` offers as
  the default `bot_account` — the identity Aiur recognizes and suppresses to avoid
  self-triggered comment/event loops.

  Returns `nil` (never the token value) when no token is set or the viewer lookup
  fails, so the caller can prompt without a default instead of crashing.
  """
  @spec detect_bot_account() :: String.t() | nil
  def detect_bot_account do
    with {:ok, token} <- require_github_token(),
         {:ok, login} <- BotIdentity.fetch_authenticated_viewer_login(&Transport.default_request_fun/1, token) do
      Edit.normalize_login(login)
    else
      _ -> nil
    end
  end

  @spec detect_repo() :: String.t() | nil
  def detect_repo do
    case System.cmd("git", ["remote", "get-url", "origin"], stderr_to_stdout: true) do
      {output, 0} -> parse_repo(String.trim(output))
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc false
  @spec parse_repo(String.t()) :: String.t() | nil
  def parse_repo(url) do
    url
    |> String.replace_suffix(".git", "")
    |> String.split(~r{[/:]}, trim: true)
    |> Enum.take(-2)
    |> case do
      [owner, name] when owner != "" and name != "" -> "#{owner}/#{name}"
      _ -> nil
    end
  end
end
