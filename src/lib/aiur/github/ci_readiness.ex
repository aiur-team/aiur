defmodule Aiur.GitHub.CiReadiness do
  @moduledoc """
  Inspects whether a GitHub repository can merge the pull requests Aiur opens.

  The result deliberately describes every missing prerequisite rather than
  failing at the first one. Callers can therefore use the same inspection for
  init errors, dispatch warnings, and operator status output.
  """

  alias Aiur.GitHub.{Errors, Transport}

  @ruleset_page_limit 20

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

  @doc false
  @spec check_fun() :: (keyword() -> {:ok, result()} | {:error, term()})
  def check_fun do
    Application.get_env(:aiur, :ci_readiness_check_fun, &check/1)
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
         {:ok, default_branch} <- fetch_default_branch(request_fun, token, base_url),
         {:ok, entries} <- fetch_list(request_fun, token, "#{base_url}/contents/.github/workflows?ref=#{URI.encode(base_branch)}"),
         {:ok, workflows} <- fetch_workflows(request_fun, token, entries, base_branch),
         {:ok, required_checks} <- fetch_required_checks(request_fun, token, base_url, base_branch, default_branch) do
      {:ok, evaluate(base_branch, workflows, required_checks)}
    else
      {:error, :base_branch_missing} -> {:ok, result(base_branch, [], [], [], [:base_branch_missing])}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_default_branch(request_fun, token, base_url) do
    case request_fun.(%{method: :get, url: base_url, token: token}) do
      {:ok, %{status: 200, body: %{"default_branch" => branch}}} when is_binary(branch) -> {:ok, branch}
      {:ok, %{status: _} = response} -> {:error, Errors.github_status_error(response)}
      {:error, reason} -> {:error, Errors.classify_error({:error, reason})}
      _ -> {:error, :invalid_repository_response}
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

  defp fetch_workflows(request_fun, token, entries, base_branch) do
    entries
    |> Enum.filter(&(Map.get(&1, "type") == "file" and workflow_path?(Map.get(&1, "path", ""))))
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case fetch_workflow(request_fun, token, entry, base_branch) do
        {:ok, workflow} -> {:cont, {:ok, [workflow | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, workflows} -> {:ok, Enum.reverse(workflows)}
      error -> error
    end)
  end

  defp fetch_workflow(request_fun, token, entry, base_branch) do
    case request_fun.(%{method: :get, url: workflow_url(entry, base_branch), token: token}) do
      {:ok, %{status: 200, body: %{"content" => content}}} when is_binary(content) ->
        decode_workflow(entry, content)

      {:ok, %{status: _} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}

      _ ->
        {:error, :invalid_workflow_response}
    end
  end

  defp decode_workflow(entry, content) do
    case Base.decode64(String.replace(content, ~r/\s/, "")) do
      {:ok, source} -> {:ok, {Map.get(entry, "path", "workflow"), source}}
      :error -> {:error, :invalid_workflow_content}
    end
  end

  defp workflow_url(entry, base_branch) do
    url = Map.fetch!(entry, "url")
    separator = if String.contains?(url, "?"), do: "&", else: "?"
    url <> separator <> "ref=#{URI.encode(base_branch)}"
  end

  defp fetch_required_checks(request_fun, token, base_url, base_branch, default_branch) do
    protection_url = "#{base_url}/branches/#{URI.encode(base_branch)}/protection"

    with {:ok, protection_checks} <- fetch_protection_checks(request_fun, token, protection_url),
         {:ok, ruleset_checks} <- fetch_ruleset_checks(request_fun, token, base_url, base_branch, default_branch) do
      {:ok, Enum.uniq(protection_checks ++ ruleset_checks)}
    end
  end

  defp fetch_protection_checks(request_fun, token, protection_url) do
    case request_fun.(%{method: :get, url: protection_url, token: token}) do
      {:ok, %{status: 200, body: protection}} -> {:ok, required_checks_from(protection)}
      {:ok, %{status: 404}} -> {:ok, []}
      {:ok, %{status: _} = response} -> {:error, Errors.github_status_error(response)}
      {:error, reason} -> {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp fetch_ruleset_checks(request_fun, token, base_url, base_branch, default_branch) do
    with {:ok, summaries} <-
           fetch_ruleset_summaries(
             request_fun,
             token,
             base_url,
             base_url <> "/rulesets?includes_parents=true&per_page=100"
           ),
         {:ok, rulesets} <- fetch_ruleset_details(request_fun, token, base_url, summaries) do
      rulesets = Enum.filter(rulesets, &ruleset_applies?(&1, base_branch, default_branch))
      {:ok, rulesets |> Enum.flat_map(&required_checks_from/1) |> Enum.uniq()}
    end
  end

  defp fetch_ruleset_summaries(request_fun, token, base_url, url, pages_left \\ @ruleset_page_limit, seen \\ [], acc \\ [])

  defp fetch_ruleset_summaries(_request_fun, _token, _base_url, _url, 0, _seen, _acc), do: {:error, :ruleset_pagination_limit}

  defp fetch_ruleset_summaries(request_fun, token, base_url, url, pages_left, seen, acc) do
    if url in seen do
      {:error, :ruleset_pagination_cycle}
    else
      fetch_ruleset_page(request_fun, token, base_url, url, pages_left, seen, acc)
    end
  end

  defp fetch_ruleset_page(request_fun, token, base_url, url, pages_left, seen, acc) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: rulesets} = response} when is_list(rulesets) ->
        case Transport.parse_next_page_url(Map.get(response, :headers, %{})) do
          nil ->
            {:ok, acc ++ rulesets}

          next_url ->
            if String.starts_with?(next_url, base_url <> "/rulesets") do
              fetch_ruleset_summaries(request_fun, token, base_url, next_url, pages_left - 1, [url | seen], acc ++ rulesets)
            else
              {:error, :invalid_ruleset_pagination_url}
            end
        end

      {:ok, %{status: _} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}

      _ ->
        {:error, :invalid_ruleset_response}
    end
  end

  defp fetch_ruleset_details(request_fun, token, base_url, summaries) do
    Enum.reduce_while(summaries, {:ok, []}, fn summary, {:ok, details} ->
      case Map.get(summary, "id") do
        id when is_integer(id) or is_binary(id) ->
          case request_fun.(%{method: :get, url: "#{base_url}/rulesets/#{URI.encode(to_string(id))}", token: token}) do
            {:ok, %{status: 200, body: detail}} when is_map(detail) -> {:cont, {:ok, [detail | details]}}
            {:ok, %{status: _} = response} -> {:halt, {:error, Errors.github_status_error(response)}}
            {:error, reason} -> {:halt, {:error, Errors.classify_error({:error, reason})}}
            _ -> {:halt, {:error, :invalid_ruleset_response}}
          end

        _ ->
          {:halt, {:error, :invalid_ruleset_summary}}
      end
    end)
    |> then(fn
      {:ok, details} -> {:ok, Enum.reverse(details)}
      error -> error
    end)
  end

  defp required_checks_from(value) when is_map(value) do
    names =
      value
      |> direct_required_checks()
      |> Enum.map(&required_check_name/1)

    nested =
      value
      |> Map.get("rules", [])
      |> List.wrap()
      |> Enum.filter(&(Map.get(&1, "type") == "required_status_checks"))
      |> Enum.flat_map(&required_checks_from/1)

    (names ++ nested) |> Enum.filter(&valid_name?/1) |> Enum.uniq()
  end

  defp required_checks_from(_), do: []

  defp direct_required_checks(value) do
    [
      get_in(value, ["required_status_checks", "contexts"]),
      get_in(value, ["required_status_checks", "checks"]),
      get_in(value, ["parameters", "required_status_checks"])
    ]
    |> Enum.flat_map(&List.wrap/1)
  end

  defp required_check_name(item) when is_map(item), do: Map.get(item, "context")
  defp required_check_name(item), do: item

  defp pull_request_workflow?(source, base_branch) do
    case YamlElixir.read_from_string(source) do
      {:ok, workflow} ->
        trigger = Map.get(workflow, "on") || Map.get(workflow, true)
        pull_request_trigger?(trigger, base_branch)

      _ ->
        false
    end
  end

  defp pull_request_trigger?(trigger, base_branch) when is_map(trigger) do
    case Map.get(trigger, "pull_request") do
      nil ->
        false

      filters when is_map(filters) ->
        universal_pull_request_filter?(filters, base_branch)

      _ ->
        true
    end
  end

  defp pull_request_trigger?(trigger, _base_branch) when is_list(trigger), do: "pull_request" in trigger
  defp pull_request_trigger?("pull_request", _base_branch), do: true
  defp pull_request_trigger?(_, _base_branch), do: false

  defp universal_pull_request_filter?(filters, base_branch) do
    branch_matches?(Map.get(filters, "branches"), base_branch) and
      not ignored_branch?(Map.get(filters, "branches-ignore"), base_branch) and
      normal_pull_request_types?(Map.get(filters, "types")) and
      no_path_filters?(filters)
  end

  defp normal_pull_request_types?(nil), do: true
  defp normal_pull_request_types?(types) when is_list(types), do: "opened" in types and "synchronize" in types
  defp normal_pull_request_types?(_types), do: false

  defp no_path_filters?(filters), do: Map.get(filters, "paths") in [nil, []] and Map.get(filters, "paths-ignore") in [nil, []]

  defp branch_matches?(nil, _base_branch), do: true
  defp branch_matches?(branches, base_branch) when is_list(branches), do: Enum.any?(branches, &glob_matches?(&1, base_branch))
  defp branch_matches?(branch, base_branch), do: glob_matches?(branch, base_branch)

  defp ignored_branch?(nil, _base_branch), do: false
  defp ignored_branch?(branches, base_branch) when is_list(branches), do: Enum.any?(branches, &glob_matches?(&1, base_branch))
  defp ignored_branch?(branch, base_branch), do: glob_matches?(branch, base_branch)

  defp glob_matches?(pattern, branch) when is_binary(pattern) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\\?", "[^/]")

    Regex.match?(Regex.compile!("^#{regex}$"), branch)
  end

  defp glob_matches?(_, _), do: false

  defp ruleset_applies?(ruleset, base_branch, default_branch) do
    ref_name = get_in(ruleset, ["conditions", "ref_name"]) || %{}
    includes = Map.get(ref_name, "include")
    excludes = Map.get(ref_name, "exclude")
    branch_ref = "refs/heads/#{base_branch}"

    Map.get(ruleset, "enforcement", "active") == "active" and
      ruleset_includes_branch?(includes, branch_ref, base_branch, default_branch) and
      not ruleset_excludes_branch?(excludes, branch_ref, base_branch, default_branch)
  end

  defp ruleset_includes_branch?(nil, _branch_ref, _base_branch, _default_branch), do: true
  defp ruleset_excludes_branch?(nil, _branch_ref, _base_branch, _default_branch), do: false

  defp ruleset_includes_branch?(patterns, branch_ref, base_branch, default_branch),
    do: ruleset_branch_matches?(patterns, branch_ref, base_branch, default_branch)

  defp ruleset_excludes_branch?(patterns, branch_ref, base_branch, default_branch),
    do: ruleset_branch_matches?(patterns, branch_ref, base_branch, default_branch)

  defp ruleset_branch_matches?(patterns, branch_ref, base_branch, default_branch) do
    patterns
    |> List.wrap()
    |> Enum.any?(fn
      "~ALL" -> true
      "~DEFAULT_BRANCH" -> base_branch == default_branch
      pattern -> glob_matches?(pattern, branch_ref)
    end)
  end

  defp workflow_check_names({_path, source}) do
    with {:ok, workflow} <- YamlElixir.read_from_string(source), jobs when is_map(jobs) <- Map.get(workflow, "jobs") do
      jobs
      |> Enum.filter(fn {_id, job} -> job_runs_on_pull_request?(job) end)
      |> Enum.map(&workflow_check_name/1)
    else
      _ -> []
    end
  end

  defp workflow_check_name({id, job}) do
    if valid_name?(Map.get(job, "name")), do: Map.get(job, "name"), else: to_string(id)
  end

  defp job_runs_on_pull_request?(job) when is_map(job) do
    case Map.get(job, "if") do
      nil -> true
      condition when is_binary(condition) -> unconditional_pull_request_condition?(condition)
      _ -> false
    end
  end

  defp job_runs_on_pull_request?(_job), do: false

  defp unconditional_pull_request_condition?(condition) do
    condition =
      condition
      |> String.trim()
      |> String.replace_prefix("${{", "")
      |> String.replace_suffix("}}", "")
      |> String.trim()

    condition == "always()" or Regex.match?(~r/^github\.event_name\s*==\s*['\"]pull_request['\"]$/, condition)
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
