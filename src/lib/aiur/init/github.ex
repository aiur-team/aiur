defmodule Aiur.Init.GitHub do
  @moduledoc """
  GitHub API adapters for the `aiur init` wizard — label management, login
  detection, and repo detection. All network calls are isolated here so the
  rest of the wizard stays pure and testable.
  """

  alias Aiur.{Codeowners.Edit, Config, Workflow}
  alias Aiur.GitHub.BotIdentity
  alias Aiur.GitHub.CiReadiness
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.HostCommand
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

  @doc "Checks that the target repository can merge an Aiur-created PR."
  @spec check_ci_readiness(map()) :: {:ok, CiReadiness.result()} | {:error, term()}
  def check_ci_readiness(%{kind: "github", repo: repo} = tracker) when is_binary(repo) do
    opts = [repo: repo, base_branch: Config.base_branch(tracker)]

    case readiness_operator_token() do
      token when is_binary(token) -> CiReadiness.check(Keyword.put(opts, :token, token))
      _ -> CiReadiness.check(Keyword.put(opts, :workflow_presence_only, true))
    end
  end

  def check_ci_readiness(%{kind: "github"}), do: {:error, :missing_github_repo}
  def check_ci_readiness(_tracker), do: {:ok, %{ready?: true}}

  @doc false
  @spec ensure_ci_readiness(Aiur.Init.Runtime.io(), Aiur.Init.Runtime.deps(), map()) :: :ok | {:error, String.t()}
  def ensure_ci_readiness(io, deps, %{kind: "github"} = tracker) do
    readiness_check = Map.get(deps, :check_ci_readiness, &check_ci_readiness/1)
    tracker = resolve_repo_for_readiness(tracker, deps)
    check_tracker = Map.drop(tracker, [:config_path])

    readiness_check.(check_tracker)
    |> handle_readiness_result(io, deps, tracker)
  end

  def ensure_ci_readiness(_io, _deps, _tracker), do: :ok

  defp handle_readiness_result({:ok, %{ready?: true} = readiness}, io, _deps, tracker) do
    case persist_operator_assessment(readiness, tracker) do
      :ok ->
        io.puts.(CiReadiness.format(readiness))
        :ok

      {:error, reason} ->
        {:error, "Repository CI readiness was verified but could not be saved for the daemon: #{inspect(reason)}"}
    end
  end

  defp handle_readiness_result({:ok, %{issues: [:base_branch_missing]} = readiness}, _io, _deps, tracker),
    do: {:error, missing_base_branch_message(tracker, readiness)}

  defp handle_readiness_result({:ok, readiness}, io, deps, tracker) do
    case persist_operator_assessment(readiness, tracker) do
      :ok ->
        io.puts.(ci_readiness_purpose() <> "\n" <> CiReadiness.format(readiness))
        maybe_scaffold_ci(io, deps, readiness, tracker)
        {:error, "Repository CI readiness is incomplete. Configure the reported gate, then run aiur init again."}

      {:error, reason} ->
        {:error, "Repository CI readiness could not be saved for the daemon: #{inspect(reason)}"}
    end
  end

  defp handle_readiness_result({:error, {:repository_access_failed, reason}}, _io, _deps, tracker),
    do: {:error, repository_access_message(tracker, reason)}

  defp handle_readiness_result({:error, {:github_org_repository_not_accessible, _detail} = reason}, _io, _deps, _tracker) do
    {:error, CiReadiness.error_message(reason) <> " This check used #{active_readiness_credential_source()}."}
  end

  defp handle_readiness_result({:error, {:ci_readiness_plan_limit, message}}, io, _deps, _tracker) do
    io.puts.(
      "GitHub reports: #{message}\n" <>
        "This repository plan does not support the ruleset or classic branch-protection checks needed for full CI readiness verification. " <>
        "Make the repository public, upgrade the plan, or continue without ruleset verification. " <>
        "aiur init is continuing without ruleset verification and will not save a CI-readiness assessment."
    )

    :ok
  end

  defp handle_readiness_result({:error, reason}, _io, _deps, _tracker),
    do: {:error, readiness_error_message(reason)}

  defp resolve_repo_for_readiness(%{repo: repo} = tracker, _deps) when is_binary(repo), do: tracker
  defp resolve_repo_for_readiness(tracker, deps), do: Map.put(tracker, :repo, deps.detect_repo.())

  defp persist_operator_assessment(readiness, tracker) do
    case readiness_operator_token() do
      token when is_binary(token) ->
        CiReadiness.persist_assessment(readiness,
          repo: tracker.repo,
          base_branch: Config.base_branch(tracker),
          config_path: Map.get(tracker, :config_path, Workflow.workflow_file_path())
        )

      _ ->
        :ok
    end
  end

  defp readiness_error_message({:github, :http, %{status: 403}}) do
    "Repository CI readiness could not be inspected: GitHub denied access to the readiness endpoints. " <>
      operator_readiness_token_guidance()
  end

  defp readiness_error_message(:ci_readiness_operator_token_required) do
    "Repository CI readiness found a pull-request workflow, but without an operator-only #{CiReadiness.operator_token_env()} it can only confirm that the workflow exists, not that failed checks block merging. " <>
      operator_readiness_token_guidance()
  end

  defp readiness_error_message(reason), do: CiReadiness.error_message(reason)

  defp ci_readiness_purpose do
    "Pull-request workflows run checks, while making `ci / required` a required status check prevents failed work from merging."
  end

  defp operator_readiness_token_guidance do
    env = CiReadiness.operator_token_env()

    "Use a fine-grained token with Contents, Actions, and Administration: Read-only for this one init command. " <>
      "In bash or zsh, run `read -rsp '#{env}: ' #{env}; echo`, `export #{env}`, `aiur init`, then `unset #{env}`. " <>
      "Never save it in `~/.aiur/.env`, the repository `.env`, " <>
      "or the daemon environment; keeping this admin-capable credential one-shot prevents agents running with bypassed permissions from accessing it."
  end

  defp missing_base_branch_message(tracker, readiness) do
    repo = tracker.repo
    base_branch = Map.get(readiness, :base_branch, Config.base_branch(tracker))

    "Repository #{repo} is visible, but configured branch `#{base_branch}` from `tracker.base_branch` does not exist. " <>
      "Check the repository default with `gh api repos/#{repo} -q .default_branch`, update `tracker.base_branch`, then rerun `aiur init`."
  end

  defp repository_access_message(tracker, reason) do
    repo = tracker.repo
    base_branch = Config.base_branch(tracker)
    credential_source = active_readiness_credential_source()

    "Repository CI readiness could not access #{repo} while checking configured branch `#{base_branch}` from `tracker.base_branch` " <>
      "with #{credential_source} (#{format_access_reason(reason)}). Authorize #{credential_source} for #{repo}; " <>
      "if the organization enforces SAML SSO, authorize that token for SAML SSO too. " <>
      "Check the repository default with `gh api repos/#{repo} -q .default_branch`, then rerun `aiur init`."
  end

  defp active_readiness_credential_source do
    case readiness_operator_token() do
      token when is_binary(token) -> CiReadiness.operator_token_env()
      _ -> "GITHUB_TOKEN"
    end
  end

  defp readiness_operator_token do
    case System.get_env(CiReadiness.operator_token_env()) do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  defp format_access_reason({:github, _kind, %{status: status}}), do: "GitHub HTTP #{status}"
  defp format_access_reason(reason), do: inspect(reason)

  defp maybe_scaffold_ci(io, deps, %{workflow_paths: []}, tracker) do
    if io.confirm.("No pull-request CI workflow found — scaffold .github/workflows/ci.yml?", true) do
      path = Path.join([deps.repo_root.(), ".github", "workflows", "ci.yml"])
      scaffold_ci(io, path, Config.base_branch(tracker))
    end
  end

  defp maybe_scaffold_ci(_io, _deps, _readiness, _tracker), do: :ok

  defp scaffold_ci(io, path, base_branch) do
    case File.exists?(path) do
      true -> io.puts.("CI scaffold skipped: #{path} already exists.")
      false -> report_scaffold_write(io, path, base_branch, write_scaffold(path))
    end
  end

  defp report_scaffold_write(io, path, base_branch, :ok) do
    io.puts.(
      "Created #{path}. Its placeholder fails closed: replace it with the repository's real test command and confirm `ci / required` passes on a pull request. " <>
        "Then open GitHub Settings → Rules → Rulesets for branch `#{base_branch}` and make that check required so failed work cannot merge; " <>
        "finally rerun `aiur init`."
    )
  end

  defp report_scaffold_write(io, _path, _base_branch, {:error, reason}),
    do: io.puts.("CI scaffold could not be written: #{inspect(reason)}")

  defp write_scaffold(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> File.write(path, CiReadiness.scaffold())
      {:error, reason} -> {:error, reason}
    end
  end

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
    case HostCommand.run(["api", "user", "--jq", ".login"], stderr_to_stdout: true, bot_token: true) do
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

  Returns `nil` (never the token value) when no token is set, the viewer lookup
  fails, or the request raises, so the caller can prompt without a default
  instead of crashing. `request_fun` is injectable for tests.
  """
  @spec detect_bot_account((map() -> {:ok, map()} | {:error, term()})) :: String.t() | nil
  def detect_bot_account(request_fun \\ &Transport.default_request_fun/1) do
    with {:ok, token} <- require_github_token(),
         {:ok, login} <- BotIdentity.fetch_authenticated_viewer_login(request_fun, token) do
      Edit.normalize_login(login)
    else
      _ -> nil
    end
  rescue
    _ -> nil
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
  @spec detect_default_branch(String.t() | nil) :: String.t() | nil
  @spec detect_default_branch(String.t() | nil, (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})) :: String.t() | nil
  def detect_default_branch(repo, command_fun \\ &host_command/3)

  def detect_default_branch(nil, _command_fun), do: nil

  def detect_default_branch(repo, command_fun) when is_binary(repo) and is_function(command_fun, 3) do
    case command_fun.("gh", ["api", "repos/#{repo}", "--jq", ".default_branch"], stderr_to_stdout: true) do
      {output, 0} ->
        case String.trim(output) do
          "" -> nil
          branch -> branch
        end

      {_output, _status} ->
        nil
    end
  rescue
    _error -> nil
  end

  # The default `command_fun` for `detect_default_branch/2`: `gh` goes through
  # the budget guard and names the daemon's credential, so the wizard's repo
  # probe is admitted and recorded like every other call (#2353).
  defp host_command("gh", args, opts), do: HostCommand.run(args, Keyword.put(opts, :bot_token, true))
  defp host_command(command, args, opts), do: System.cmd(command, args, opts)

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
