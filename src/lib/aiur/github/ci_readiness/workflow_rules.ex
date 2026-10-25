defmodule Aiur.GitHub.CiReadiness.WorkflowRules do
  @moduledoc """
  Pure rules for CI readiness: which workflows run on a pull request to the
  base branch, which rulesets apply to it, and which check names a workflow
  produces once its job matrices are expanded.
  """

  @matrix_ref_regex ~r/\$\{\{\s*matrix\.([A-Za-z0-9_.-]+)\s*\}\}/

  @doc false
  @spec pull_request_workflow?(String.t(), String.t()) :: boolean()
  def pull_request_workflow?(source, base_branch) do
    case Aiur.Yaml.read_from_string(source) do
      {:ok, workflow} ->
        trigger = Map.get(workflow, "on") || Map.get(workflow, true)
        pull_request_trigger?(trigger, base_branch)

      _ ->
        false
    end
  end

  defp pull_request_trigger?(trigger, base_branch) when is_map(trigger) do
    case Map.fetch(trigger, "pull_request") do
      :error -> false
      {:ok, filters} when is_map(filters) -> universal_pull_request_filter?(filters, base_branch)
      {:ok, _filters} -> true
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

  defp branch_matches?(branches, base_branch) when is_list(branches) do
    branches
    |> Enum.reduce(false, fn
      "!" <> pattern, matched? -> if glob_matches?(pattern, base_branch), do: false, else: matched?
      pattern, matched? -> if glob_matches?(pattern, base_branch), do: true, else: matched?
    end)
  end

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

  @doc false
  @spec ruleset_applies?(map(), String.t(), String.t()) :: boolean()
  def ruleset_applies?(ruleset, base_branch, default_branch) do
    ref_name = get_in(ruleset, ["conditions", "ref_name"]) || %{}
    includes = Map.get(ref_name, "include")
    excludes = Map.get(ref_name, "exclude")
    branch_ref = "refs/heads/#{base_branch}"

    Map.get(ruleset, "enforcement", "active") == "active" and
      ruleset_includes_branch?(includes, branch_ref, base_branch, default_branch) and
      not ruleset_excludes_branch?(excludes, branch_ref, base_branch, default_branch)
  end

  defp ruleset_includes_branch?(nil, _branch_ref, _base_branch, _default_branch), do: true

  defp ruleset_includes_branch?(patterns, branch_ref, base_branch, default_branch),
    do: ruleset_branch_matches?(patterns, branch_ref, base_branch, default_branch)

  defp ruleset_excludes_branch?(nil, _branch_ref, _base_branch, _default_branch), do: false

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

  @doc false
  @spec workflow_check_names({String.t(), String.t()}) :: [String.t()]
  def workflow_check_names({_path, source}) do
    with {:ok, workflow} <- Aiur.Yaml.read_from_string(source), jobs when is_map(jobs) <- Map.get(workflow, "jobs") do
      jobs
      |> Enum.filter(fn {_id, job} -> job_runs_on_pull_request?(job) end)
      |> Enum.flat_map(&job_check_names/1)
    else
      _ -> []
    end
  end

  # GitHub runs one check per matrix combination, each named by substituting the
  # combination's values into the job `name` template. Without this expansion a
  # `coverage (${{ matrix.partition }}/4)` job would never match the required
  # `coverage (1/4)`..`(4/4)` checks and every repository using a named matrix
  # job would be assessed as permanently not ready.
  defp job_check_names({id, job}) do
    name = if valid_name?(Map.get(job, "name")), do: Map.get(job, "name"), else: to_string(id)

    case matrix_combinations(job) do
      [] -> [name]
      combinations -> Enum.map(combinations, &substitute_matrix(name, &1))
    end
  end

  defp matrix_combinations(job) when is_map(job) do
    case get_in(job, ["strategy", "matrix"]) do
      matrix when is_map(matrix) and map_size(matrix) > 0 -> expand_matrix_combinations(matrix)
      _ -> []
    end
  end

  defp expand_matrix_combinations(matrix) do
    axes = Map.drop(matrix, ["include", "exclude"])

    axes
    |> cartesian_product()
    |> reject_matrix_excludes(List.wrap(Map.get(matrix, "exclude")))
    |> apply_matrix_includes(List.wrap(Map.get(matrix, "include")))
  end

  defp cartesian_product(axes) when map_size(axes) == 0, do: [%{}]

  defp cartesian_product(axes) do
    Enum.reduce(axes, [%{}], fn {key, values}, combinations ->
      for combination <- combinations, value <- List.wrap(values), do: Map.put(combination, key, value)
    end)
  end

  defp reject_matrix_excludes(combinations, excludes) do
    Enum.reject(combinations, fn combination ->
      Enum.any?(excludes, &matrix_entry_matches?(combination, &1))
    end)
  end

  defp apply_matrix_includes(combinations, []) do
    combinations
  end

  defp apply_matrix_includes(combinations, includes) do
    includes
    |> Enum.reduce(combinations, &merge_include_entry(&2, &1))
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp merge_include_entry(combinations, entry) do
    case matching_include_indices(combinations, entry) do
      [] -> [entry | combinations]
      indices -> Enum.reduce(indices, combinations, &merge_include_index(&2, &1, entry))
    end
  end

  defp matching_include_indices(combinations, entry) do
    combinations
    |> Enum.with_index()
    |> Enum.filter(fn {combination, _index} -> include_matches?(combination, entry) end)
    |> Enum.map(fn {_combination, index} -> index end)
  end

  defp merge_include_index(combinations, index, entry) do
    List.update_at(combinations, index, &Map.merge(&1, entry))
  end

  defp include_matches?(combination, entry) when is_map(combination) and is_map(entry) do
    Enum.all?(Map.keys(combination), fn key ->
      case Map.fetch(entry, key) do
        {:ok, expected} -> Map.fetch!(combination, key) == expected
        :error -> true
      end
    end)
  end

  defp include_matches?(_combination, _entry), do: false

  defp matrix_entry_matches?(combination, entry) when is_map(combination) and is_map(entry) do
    Enum.all?(entry, fn {key, expected} ->
      case Map.fetch(combination, key) do
        {:ok, actual} -> actual == expected
        :error -> false
      end
    end)
  end

  defp matrix_entry_matches?(_combination, _entry), do: false

  defp substitute_matrix(name, combination) do
    Regex.replace(@matrix_ref_regex, name, fn
      match, key ->
        case resolve_matrix_value(combination, key) do
          nil -> match
          value when is_map(value) -> match
          value -> to_string(value)
        end
    end)
  end

  defp resolve_matrix_value(combination, key) do
    Enum.reduce_while(String.split(key, "."), combination, fn part, acc ->
      case acc do
        %{^part => value} -> {:cont, value}
        _ -> {:halt, nil}
      end
    end)
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

    ready_gates = ["github.event_name != 'pull_request' || !github.event.pull_request.draft", "needs.changes.outputs.draft != 'true'"]
    ready_conditions = for g <- ready_gates, c <- [g, "always() && (#{g})", "!cancelled() && (#{g})"], do: c

    condition in ["always()", "!cancelled()" | ready_conditions] or
      Regex.match?(~r/^github\.event_name\s*==\s*['\"]pull_request['\"]$/, condition)
  end

  @doc false
  @spec valid_name?(term()) :: boolean()
  def valid_name?(value), do: is_binary(value) and String.trim(value) != ""
end
