defmodule Aiur.GitHub.CiReadiness do
  @moduledoc """
  Inspects whether a GitHub repository can merge the pull requests Aiur opens.

  The result deliberately describes every missing prerequisite rather than
  failing at the first one. Callers can therefore use the same inspection for
  init errors, dispatch warnings, and operator status output.
  """

  alias Aiur.GitHub.{Errors, Transport}

  @type issue ::
          :base_branch_missing
          | :no_pr_workflow
          | :no_required_check
          | {:required_check_not_produced, [String.t()]}
          | {:unavailable, term()}

  @type result :: %{
          ready?: boolean(),
          base_branch: String.t(),
          workflow_paths: [String.t()],
          workflow_check_names: [String.t()],
          required_checks: [String.t()],
          issues: [issue()]
        }

  @spec check(keyword()) :: {:ok, result()} | {:error, term()}
  def check(opts \\ []) do
    with {:ok, {owner, repo}} <- resolve_repo(Keyword.get(opts, :repo)),
         {:ok, token} <- Transport.require_token(opts) do
      base_branch = Keyword.get(opts, :base_branch, "main")
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      inspect_repository(request_fun, token, owner, repo, base_branch)
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
  def inspect_repository(request_fun, token, owner, repo, base_branch)
      when is_function(request_fun, 1) and is_binary(token) and is_binary(base_branch) do
    base_url = "#{Transport.base_url()}/repos/#{owner}/#{repo}"

    with :ok <- branch_exists?(request_fun, token, "#{base_url}/branches/#{URI.encode(base_branch)}"),
         {:ok, entries} <- fetch_list(request_fun, token, "#{base_url}/contents/.github/workflows?ref=#{URI.encode(base_branch)}"),
         {:ok, workflows} <- fetch_workflows(request_fun, token, entries),
         {:ok, required_checks} <- fetch_required_checks(request_fun, token, base_url, base_branch) do
      {:ok, evaluate(base_branch, workflows, required_checks)}
    else
      {:error, :base_branch_missing} -> {:ok, result(base_branch, [], [], [], [:base_branch_missing])}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Pure readiness decision used by the HTTP adapter and tests."
  @spec evaluate(String.t(), [{String.t(), String.t()}], [String.t()]) :: result()
  def evaluate(base_branch, workflows, required_checks)
      when is_binary(base_branch) and is_list(workflows) and is_list(required_checks) do
    pr_workflows = Enum.filter(workflows, fn {_path, source} -> pull_request_workflow?(source, base_branch) end)
    workflow_check_names = pr_workflows |> Enum.flat_map(&workflow_check_names/1) |> Enum.uniq() |> Enum.sort()
    required_checks = required_checks |> Enum.filter(&valid_name?/1) |> Enum.uniq() |> Enum.sort()

    issues =
      []
      |> maybe_add(pr_workflows == [], :no_pr_workflow)
      |> maybe_add(required_checks == [], :no_required_check)
      |> maybe_add(
        required_checks != [] and Enum.any?(required_checks, &(&1 not in workflow_check_names)),
        {:required_check_not_produced, required_checks -- workflow_check_names}
      )

    result(base_branch, Enum.map(pr_workflows, &elem(&1, 0)), workflow_check_names, required_checks, issues)
  end

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
          - run: echo 'Replace this with your project test command.'
    """
  end

  defp branch_exists?(request_fun, token, url) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> {:error, :base_branch_missing}
      {:ok, %{status: _} = response} -> {:error, Errors.github_status_error(response)}
      {:error, reason} -> {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp fetch_list(request_fun, token, url) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body}} when is_list(body) -> {:ok, body}
      {:ok, %{status: 404}} -> {:ok, []}
      {:ok, %{status: _} = response} -> {:error, Errors.github_status_error(response)}
      {:error, reason} -> {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp fetch_workflows(request_fun, token, entries) do
    entries
    |> Enum.filter(&(Map.get(&1, "type") == "file" and workflow_path?(Map.get(&1, "path", ""))))
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case request_fun.(%{method: :get, url: Map.fetch!(entry, "url"), token: token}) do
        {:ok, %{status: 200, body: %{"content" => content}}} when is_binary(content) ->
          case Base.decode64(String.replace(content, ~r/\s/, "")) do
            {:ok, source} -> {:cont, {:ok, [{Map.get(entry, "path", "workflow"), source} | acc]}}
            :error -> {:halt, {:error, :invalid_workflow_content}}
          end

        {:ok, %{status: _} = response} ->
          {:halt, {:error, Errors.github_status_error(response)}}

        {:error, reason} ->
          {:halt, {:error, Errors.classify_error({:error, reason})}}

        _ ->
          {:halt, {:error, :invalid_workflow_response}}
      end
    end)
    |> then(fn
      {:ok, workflows} -> {:ok, Enum.reverse(workflows)}
      error -> error
    end)
  end

  defp fetch_required_checks(request_fun, token, base_url, base_branch) do
    protection_url = "#{base_url}/branches/#{URI.encode(base_branch)}/protection"

    case request_fun.(%{method: :get, url: protection_url, token: token}) do
      {:ok, %{status: 200, body: protection}} -> {:ok, required_checks_from(protection)}
      {:ok, %{status: 404}} -> fetch_ruleset_checks(request_fun, token, base_url)
      {:ok, %{status: _} = response} -> {:error, Errors.github_status_error(response)}
      {:error, reason} -> {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp fetch_ruleset_checks(request_fun, token, base_url) do
    case request_fun.(%{method: :get, url: base_url <> "/rulesets?includes_parents=true", token: token}) do
      {:ok, %{status: 200, body: rulesets}} when is_list(rulesets) ->
        {:ok, rulesets |> Enum.flat_map(&required_checks_from/1) |> Enum.uniq()}

      {:ok, %{status: _} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp required_checks_from(value) when is_map(value) do
    direct = get_in(value, ["required_status_checks", "contexts"]) || get_in(value, ["parameters", "required_status_checks"])

    names =
      case direct do
        contexts when is_list(contexts) -> Enum.map(contexts, fn item -> if is_map(item), do: Map.get(item, "context"), else: item end)
        _ -> []
      end

    nested =
      value
      |> Map.get("rules", [])
      |> List.wrap()
      |> Enum.filter(&(Map.get(&1, "type") == "required_status_checks"))
      |> Enum.flat_map(&required_checks_from/1)

    (names ++ nested) |> Enum.filter(&valid_name?/1) |> Enum.uniq()
  end

  defp required_checks_from(_), do: []

  defp pull_request_workflow?(source, base_branch) do
    with {:ok, workflow} <- YamlElixir.read_from_string(source) do
      trigger = Map.get(workflow, "on") || Map.get(workflow, true)
      pull_request_trigger?(trigger, base_branch)
    else
      _ -> false
    end
  end

  defp pull_request_trigger?(trigger, base_branch) when is_map(trigger) do
    case Map.get(trigger, "pull_request") do
      nil -> false
      branches when is_map(branches) -> branch_matches?(Map.get(branches, "branches"), base_branch)
      _ -> true
    end
  end

  defp pull_request_trigger?(trigger, _base_branch) when is_list(trigger), do: "pull_request" in trigger
  defp pull_request_trigger?("pull_request", _base_branch), do: true
  defp pull_request_trigger?(_, _base_branch), do: false

  defp branch_matches?(nil, _base_branch), do: true
  defp branch_matches?(branches, base_branch) when is_list(branches), do: Enum.any?(branches, &glob_matches?(&1, base_branch))
  defp branch_matches?(branch, base_branch), do: glob_matches?(branch, base_branch)

  defp glob_matches?(pattern, branch) when is_binary(pattern), do: pattern == branch or pattern == "**"
  defp glob_matches?(_, _), do: false

  defp workflow_check_names({_path, source}) do
    with {:ok, workflow} <- YamlElixir.read_from_string(source), jobs when is_map(jobs) <- Map.get(workflow, "jobs") do
      Enum.flat_map(jobs, fn {id, job} -> [if(is_map(job) && valid_name?(Map.get(job, "name")), do: Map.get(job, "name"), else: to_string(id))] end)
    else
      _ -> []
    end
  end

  defp workflow_path?(path), do: String.ends_with?(path, ".yml") or String.ends_with?(path, ".yaml")
  defp valid_name?(value), do: is_binary(value) and String.trim(value) != ""
  defp maybe_add(issues, true, issue), do: issues ++ [issue]
  defp maybe_add(issues, false, _issue), do: issues

  defp result(base_branch, workflow_paths, workflow_check_names, required_checks, issues) do
    %{
      ready?: issues == [],
      base_branch: base_branch,
      workflow_paths: workflow_paths,
      workflow_check_names: workflow_check_names,
      required_checks: required_checks,
      issues: issues
    }
  end

  defp format_issue(:base_branch_missing), do: "configured base branch does not exist"
  defp format_issue(:no_pr_workflow), do: "no workflow triggers on pull_request"
  defp format_issue(:no_required_check), do: "no required status check is configured"
  defp format_issue({:required_check_not_produced, checks}), do: "required check is not produced: #{Enum.join(checks, ", ")}"
  defp format_issue({:unavailable, reason}), do: "inspection unavailable: #{inspect(reason)}"
end
