defmodule Aiur.GlobalConfigStartup do
  @moduledoc "Pre-dispatch setup when a run uses shared home-directory settings."
  alias Aiur.BuildOrder.Bounded
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.{Labels, Transport}
  alias Aiur.Workflow

  @spec prepare() :: :ok | {:error, String.t()}
  def prepare do
    # The shared test application must never bootstrap a developer repository.
    if Application.get_env(:aiur, :env) == :test, do: :ok, else: prepare(Workflow.workflow_file_path())
  end

  @spec prepare(Path.t(), keyword()) :: :ok | {:error, String.t()}
  def prepare(path, opts \\ []) do
    home = Keyword.get(opts, :home, System.get_env("HOME") || Path.expand("~"))

    if Path.expand(path) == Path.join([home, ".aiur", "config"]) do
      IO.puts(:stderr, "Using global config: #{path}; no repository-local init required.")
      with {:ok, workflow} <- Workflow.load(path), do: bootstrap(workflow.config, opts)
    else
      :ok
    end
  end

  defp bootstrap(%{"tracker" => %{"kind" => "github"} = tracker}, opts) do
    github = Map.get(tracker, "github", %{}) || %{}
    origin_fun = Keyword.get(opts, :origin_fun, fn -> github_origin(opts) end)
    token_fun = Keyword.get(opts, :token_fun, &GitHubConfig.token/0)

    with {:ok, {owner, repo}} <- target(github["repo"], origin_fun.()),
         {:ok, token} <- credential(token_fun.()) do
      IO.puts(:stderr, "Global defaults target GitHub repository #{owner}/#{repo}; ensuring workflow labels (no model labels).")
      ensure_labels(owner, repo, token, GitHubConfig.label_prefix(github["label_prefix"]), opts)
    end
  end

  defp bootstrap(_config, _opts), do: :ok

  defp github_origin(opts) do
    remote = Keyword.get(opts, :origin_url_fun, &origin_url/0).()
    if is_binary(remote) and github_host?(remote), do: Aiur.Git.parse_origin_url(remote), else: nil
  end

  defp github_host?(remote) do
    String.downcase(URI.parse(remote).host || "") == "github.com" or
      Regex.match?(~r/\A(?:[^@:\/]+@)?github\.com:/i, remote)
  end

  defp origin_url do
    case System.cmd("git", ["remote", "get-url", "origin"], stderr_to_stdout: true) do
      {url, 0} -> String.trim(url)
      _ -> nil
    end
  end

  defp target(configured, origin) when is_binary(origin) do
    configured = if is_binary(configured), do: String.trim(configured), else: ""

    if configured in ["", origin] do
      validate_origin(origin)
    else
      {:error, "Global tracker.github.repo #{configured} differs from origin #{origin}. Omit repo in ~/.aiur/config for portable defaults, or run aiur init for repository-specific settings."}
    end
  end

  defp target(_configured, _origin), do: {:error, "No GitHub origin repository found. Configure origin or run aiur init."}

  defp validate_origin(origin) do
    with [owner, repo] <- String.split(origin, "/"),
         {:ok, pair} <- Bounded.github_repository_components(owner, repo) do
      {:ok, pair}
    else
      _ -> {:error, "Cannot resolve a valid GitHub repository from origin."}
    end
  end

  defp credential(token) when is_binary(token) and token != "", do: {:ok, token}
  defp credential(_), do: {:error, "GitHub credential missing. Set GITHUB_TOKEN in ~/.aiur/.env, configure GitHub App credentials, or use gh auth login."}

  defp ensure_labels(owner, repo, token, prefix, opts) do
    request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
    required = Labels.state_labels(prefix) ++ Labels.marker_labels(prefix) ++ Labels.complexity_labels()

    with {:ok, existing} <- existing_labels(owner, repo, token, request, 1, []),
         :ok <- Labels.ensure(owner, repo, token, required -- existing, request_fun: request) do
      :ok
    else
      {:error, reason} ->
        {:error,
         "Global config repository setup failed for #{owner}/#{repo}: #{inspect(reason)}. Missing labels require GitHub Issues read/write permission. Correct credentials/permissions or provision workflow labels before restarting; no agents were started."}
    end
  end

  defp existing_labels(_owner, _repo, _token, _request, page, _acc) when page > 10,
    do: {:error, :label_page_limit}

  defp existing_labels(owner, repo, token, request, page, acc) do
    url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/labels?per_page=100&page=#{page}"

    case request.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: labels}} when is_list(labels) ->
        names = acc ++ Enum.map(labels, & &1["name"])
        if length(labels) == 100, do: existing_labels(owner, repo, token, request, page + 1, names), else: {:ok, names}

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end
end
