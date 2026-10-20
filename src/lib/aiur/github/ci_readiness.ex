defmodule Aiur.GitHub.CiReadiness do
  @moduledoc """
  Inspects whether a GitHub repository can merge the pull requests Aiur opens.

  The result deliberately describes every missing prerequisite rather than
  failing at the first one. Callers can therefore use the same inspection for
  init errors, dispatch warnings, and operator status output.
  """

  @behaviour Aiur.CodeHost.CiReadiness

  @impl true
  defdelegate retryable_error?(reason), to: Aiur.GitHub.Errors, as: :retryable_github_error?

  alias Aiur.{Config, Workflow}
  alias Aiur.GitHub.CiReadiness.{Assessment, RepositoryReads, WorkflowRules}
  alias Aiur.GitHub.Transport

  @default_timeout_ms 30_000
  @github_actions_app_id 15_368
  @operator_token_env "AIUR_CI_READINESS_TOKEN"

  @type issue ::
          :base_branch_missing
          | :no_pr_workflow
          | :no_required_check
          | {:required_check_not_produced, [String.t()]}
          | {:required_check_integration_not_produced, [String.t()]}
          | {:unavailable, term()}

  @type result :: %{
          ready?: boolean(),
          base_branch: String.t(),
          workflow_paths: [String.t()],
          workflow_check_names: [String.t()],
          required_checks: [String.t()],
          required_check_identities: [%{name: String.t(), app_id: integer() | nil}],
          issues: [issue()]
        }

  @spec check(keyword()) :: {:ok, result()} | {:error, term()}
  def check(opts \\ []) do
    with {:ok, {owner, repo}} <- resolve_repo(Keyword.get(opts, :repo)),
         {:ok, token} <- Transport.require_token(opts) do
      base_branch = Config.base_branch(opts)

      request_fun =
        opts
        |> Keyword.get(:request_fun, &Transport.default_request_fun/1)
        |> tag_request_credential(Keyword.get(opts, :request_credential_id))
        |> bounded_request_fun(deadline_at_ms(opts))

      inspect_repository(request_fun, token, owner, repo, base_branch, opts)
    end
  end

  @doc "Reads the current required checks without inspecting workflow contents."
  @spec fetch_required_checks(keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_required_checks(opts \\ []) do
    with {:ok, {owner, repo}} <- resolve_repo(Keyword.get(opts, :repo)),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      base_url = "#{Transport.base_url()}/repos/#{owner}/#{repo}"
      branch = RepositoryReads.encode_path_component(Config.base_branch(opts))

      with {:ok, rules} <- Transport.fetch_json_list(request_fun, token, "#{base_url}/rules/branches/#{branch}", caller: "ci_required_checks"),
           {:ok, protection} <- RepositoryReads.fetch_protection_checks(request_fun, token, "#{base_url}/branches/#{branch}/protection", "ci_required_checks") do
        {:ok, Enum.uniq(protection ++ Enum.flat_map(rules, &RepositoryReads.required_checks_from/1))}
      end
    end
  end

  @doc false
  @spec operator_token_env() :: String.t()
  def operator_token_env, do: @operator_token_env

  @doc false
  @impl true
  @spec check_fun() :: (keyword() -> {:ok, result()} | {:error, term()})
  def check_fun do
    Application.get_env(:aiur, :ci_readiness_check_fun, &dispatch_check/1)
  end

  @doc false
  @spec dispatch_check(keyword()) :: {:ok, result()} | {:error, term()}
  def dispatch_check(opts) do
    case operator_token() do
      token when is_binary(token) ->
        opts |> Keyword.put(:token, token) |> Keyword.put(:request_credential_id, "ci_readiness") |> check()

      nil ->
        {:ok, unavailable(Config.base_branch(opts), :ci_readiness_operator_token_required)}
    end
  end

  defp operator_token do
    case System.get_env(@operator_token_env) do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  defp tag_request_credential(request_fun, credential_id) when is_binary(credential_id) do
    fn request -> request_fun.(Map.put_new(request, :credential_id, credential_id)) end
  end

  defp tag_request_credential(request_fun, _credential_id), do: request_fun

  @doc false
  @impl true
  @spec unavailable(String.t(), term()) :: result()
  def unavailable(base_branch, reason) when is_binary(base_branch), do: result(base_branch, [], [], [], [{:unavailable, reason}])

  @doc "Formats a repository-readiness failure for an operator without exposing credentials."
  @impl true
  @spec error_message(term()) :: String.t()
  def error_message({:github_org_repository_not_accessible, %{organization: organization, repo: repo, token_type: token_type}}) do
    "Cannot read #{repo} with the configured token. GitHub returns 404 (not 403) for inaccessible private organization resources, " <>
      "so this may be an authorization problem rather than a missing repository or branch. " <>
      token_authorization_guidance(token_type, organization)
  end

  def error_message({:github, :http, %{status: 404}}) do
    "Cannot read the configured GitHub repository. GitHub may return 404 when a repository is absent or when the configured token cannot access it. " <>
      "Verify the repository name and the configured token's repository access."
  end

  def error_message(reason), do: "Repository CI readiness could not be inspected: #{inspect(reason)}"

  @doc false
  @impl true
  @spec cache_result(result(), keyword()) :: :ok
  defdelegate cache_result(result, opts \\ []), to: Assessment

  @doc false
  @impl true
  @spec cached_result(keyword()) :: result() | :unavailable
  defdelegate cached_result(opts \\ []), to: Assessment

  @doc "Persists a non-secret, operator-verified assessment beside the workflow config."
  @spec persist_assessment(result(), keyword()) :: :ok | {:error, term()}
  defdelegate persist_assessment(result, opts \\ []), to: Assessment

  @doc false
  @spec clear_cached_result() :: :ok
  defdelegate clear_cached_result(), to: Assessment

  @doc false
  @spec assessment_path() :: Path.t()
  @spec assessment_path(Path.t()) :: Path.t()
  defdelegate assessment_path(config_path \\ Workflow.workflow_file_path()), to: Assessment

  @doc false
  @impl true
  @spec readiness_scope(keyword()) :: {String.t(), String.t(), String.t()}
  defdelegate readiness_scope(opts \\ []), to: Assessment

  defp deadline_at_ms(opts) do
    Keyword.get(opts, :deadline_at_ms, System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, @default_timeout_ms))
  end

  defp bounded_request_fun(request_fun, deadline_at_ms) do
    fn request -> run_bounded_request(request_fun, request, deadline_at_ms) end
  end

  defp run_bounded_request(request_fun, request, deadline_at_ms) do
    remaining_ms = deadline_at_ms - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      {:error, :timeout}
    else
      await_request_result(request_fun, request, remaining_ms)
    end
  end

  defp await_request_result(request_fun, request, remaining_ms) do
    parent = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(parent, {result_ref, request_fun.(Map.put(request, :timeout_ms, remaining_ms))})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        {:error, :transport}
    after
      remaining_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor_ref, [:flush])
        {:error, :timeout}
    end
  end

  defp resolve_repo(nil), do: Transport.parse_repo()
  defp resolve_repo({owner, repo}) when is_binary(owner) and is_binary(repo), do: {:ok, {owner, repo}}

  defp resolve_repo(repo) when is_binary(repo) do
    case String.split(repo, "/", trim: true) do
      [owner, name] -> {:ok, {owner, name}}
      _ -> {:error, {:invalid_github_repo, repo}}
    end
  end

  defp resolve_repo(_), do: {:error, :missing_github_repo}

  @spec inspect_repository(function(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, result()} | {:error, term()}
  def inspect_repository(request_fun, token, owner, repo, base_branch),
    do: inspect_repository(request_fun, token, owner, repo, base_branch, [])

  @spec inspect_repository(function(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def inspect_repository(request_fun, token, owner, repo, base_branch, opts)
      when is_function(request_fun, 1) and is_binary(token) and is_binary(base_branch) do
    base_url = "#{Transport.base_url()}/repos/#{owner}/#{repo}"

    with {:ok, default_branch} <- RepositoryReads.fetch_default_branch(request_fun, token, base_url, owner, repo),
         :ok <- RepositoryReads.branch_exists?(request_fun, token, "#{base_url}/branches/#{RepositoryReads.encode_path_component(base_branch)}"),
         {:ok, entries} <- RepositoryReads.fetch_list(request_fun, token, "#{base_url}/contents/.github/workflows?ref=#{RepositoryReads.encode_query_value(base_branch)}") do
      inspect_workflow_entries(request_fun, token, base_url, base_branch, default_branch, entries, opts)
    else
      {:error, :base_branch_missing} -> {:ok, result(base_branch, [], [], [], [:base_branch_missing])}
      {:error, reason} -> {:error, reason}
    end
  end

  defp inspect_workflow_entries(request_fun, token, base_url, base_branch, default_branch, entries, opts) when is_list(entries) do
    if Keyword.get(opts, :workflow_presence_only, false) do
      inspect_workflow_presence(request_fun, token, base_branch, entries)
    else
      inspect_full_workflow_entries(request_fun, token, base_url, base_branch, default_branch, entries)
    end
  end

  defp inspect_full_workflow_entries(request_fun, token, base_url, base_branch, default_branch, entries) do
    with {:ok, workflow_states} <- RepositoryReads.fetch_workflow_states(request_fun, token, base_url, entries),
         {:ok, workflows} <- RepositoryReads.fetch_workflows(request_fun, token, entries, workflow_states, base_branch),
         {:ok, required_checks} <- RepositoryReads.fetch_required_checks_for_entries(entries, request_fun, token, base_url, base_branch, default_branch) do
      {:ok, evaluate(base_branch, workflows, required_checks)}
    end
  end

  defp inspect_workflow_presence(request_fun, token, base_branch, entries) do
    workflow_states = Map.new(entries, fn entry -> {Map.get(entry, "path"), true} end)

    with {:ok, workflows} <- RepositoryReads.fetch_workflows(request_fun, token, entries, workflow_states, base_branch) do
      readiness = evaluate(base_branch, workflows, [])

      if readiness.workflow_paths == [] do
        {:ok, readiness}
      else
        {:error, :ci_readiness_operator_token_required}
      end
    end
  end

  @doc "Pure readiness decision used by the HTTP adapter and tests."
  @spec evaluate(String.t(), [{String.t(), String.t()}], [String.t() | map()]) :: result()
  def evaluate(base_branch, workflows, required_checks)
      when is_binary(base_branch) and is_list(workflows) and is_list(required_checks) do
    pr_workflows = Enum.filter(workflows, fn {_path, source} -> WorkflowRules.pull_request_workflow?(source, base_branch) end)
    workflow_check_names = pr_workflows |> Enum.flat_map(&WorkflowRules.workflow_check_names/1) |> Enum.uniq() |> Enum.sort()
    required_check_identities = required_checks |> Enum.map(&RepositoryReads.required_check_identity/1) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort_by(& &1.name)
    required_checks = required_check_identities |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.sort()

    missing_checks = required_checks -- workflow_check_names

    integration_mismatches =
      required_check_identities
      |> Enum.filter(fn %{name: name, app_id: app_id} ->
        name in workflow_check_names and app_id not in [nil, -1, @github_actions_app_id]
      end)
      |> Enum.map(&format_check_identity/1)

    issues =
      []
      |> maybe_add(pr_workflows == [], :no_pr_workflow)
      |> maybe_add(required_checks == [], :no_required_check)
      |> maybe_add(missing_checks != [], {:required_check_not_produced, missing_checks})
      |> maybe_add(integration_mismatches != [], {:required_check_integration_not_produced, integration_mismatches})

    result(base_branch, Enum.map(pr_workflows, &elem(&1, 0)), workflow_check_names, required_checks, required_check_identities, issues)
  end

  @impl true
  @spec format(result() | term()) :: String.t()
  def format(%{ready?: true, base_branch: base_branch, required_checks: checks}) do
    "CI readiness: ready for #{base_branch} (required: #{Enum.join(checks, ", ")})"
  end

  def format(%{base_branch: base_branch, issues: issues}) do
    "CI readiness: not ready for #{base_branch} — " <> Enum.map_join(issues, "; ", &format_issue/1)
  end

  def format(other), do: "CI readiness: unavailable (#{inspect(other)})"

  @spec scaffold(String.t()) :: String.t()
  def scaffold(required_check_name \\ "ci / required") do
    """
    name: CI

    on:
      pull_request:

    jobs:
      required:
        name: #{required_check_name}
        runs-on: ubuntu-latest
        steps:
          - run: echo 'Replace this with your project test command.' >&2; exit 1
    """
  end

  defp maybe_add(issues, true, issue), do: issues ++ [issue]
  defp maybe_add(issues, false, _issue), do: issues

  defp result(base_branch, workflow_paths, workflow_check_names, required_checks, issues),
    do: result(base_branch, workflow_paths, workflow_check_names, required_checks, [], issues)

  defp result(base_branch, workflow_paths, workflow_check_names, required_checks, required_check_identities, issues) do
    %{
      ready?: issues == [],
      base_branch: base_branch,
      workflow_paths: workflow_paths,
      workflow_check_names: workflow_check_names,
      required_checks: required_checks,
      required_check_identities: required_check_identities,
      issues: issues
    }
  end

  defp format_issue(:base_branch_missing), do: "configured base branch does not exist"
  defp format_issue(:no_pr_workflow), do: "no workflow triggers on pull_request"
  defp format_issue(:no_required_check), do: "no required status check is configured"
  defp format_issue({:required_check_not_produced, checks}), do: "required check is not produced: #{Enum.join(checks, ", ")}"
  defp format_issue({:required_check_integration_not_produced, checks}), do: "required check is pinned to a different GitHub App: #{Enum.join(checks, ", ")}"

  defp format_issue({:unavailable, :ci_readiness_operator_token_required}),
    do: "inspection unavailable: configure operator-only #{operator_token_env()} to inspect required checks and workflows"

  defp format_issue({:unavailable, "ci_readiness_operator_token_required"}),
    do: "inspection unavailable: configure operator-only #{operator_token_env()} to inspect required checks and workflows"

  defp format_issue({:unavailable, ":ci_readiness_operator_token_required"}),
    do: "inspection unavailable: configure operator-only #{operator_token_env()} to inspect required checks and workflows"

  defp format_issue({:unavailable, reason}), do: "inspection unavailable: #{inspect(reason)}"

  defp token_authorization_guidance(:classic_pat, organization) do
    "Your token looks like a classic PAT (`ghp_…`). It needs the `repo` scope and SAML SSO authorization for #{organization}. " <>
      "In GitHub, open Settings → Developer settings → Personal access tokens → Tokens (classic) → Configure SSO → Authorize. " <>
      "If `gh api` succeeds, it may be using a different OAuth token (`gho_…`) from the `gh` keyring; that does not authorize this configured token."
  end

  defp token_authorization_guidance(:fine_grained_pat, organization) do
    "Your token looks like a fine-grained PAT (`github_pat_…`). It must be created with #{organization} as its resource owner, include this repository, " <>
      "and may require organization approval. A token owned by your personal account cannot be granted access to this organization repository. " <>
      "If `gh api` succeeds, it may be using a different OAuth token (`gho_…`) from the `gh` keyring."
  end

  defp token_authorization_guidance(:oauth, organization) do
    "Your token looks like an OAuth token (`gho_…`). Verify that the OAuth app access is authorized for #{organization} and that the token's user can read this repository."
  end

  defp token_authorization_guidance(:app_installation, organization) do
    "Your token looks like a GitHub App installation token (`ghs_…`). Verify that the App is installed on this repository in #{organization} with Contents: Read access."
  end

  defp token_authorization_guidance(:unknown, organization) do
    "The credential type is not recognized from its prefix. Verify its repository permissions and organization authorization for #{organization}; " <>
      "also verify whether `gh api` is using a different credential from the `gh` keyring."
  end

  defp format_check_identity(%{name: name, app_id: app_id}), do: "#{name} (app_id: #{app_id})"
end
