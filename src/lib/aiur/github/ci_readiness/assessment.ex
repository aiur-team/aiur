defmodule Aiur.GitHub.CiReadiness.Assessment do
  @moduledoc """
  In-memory cache and `ci-readiness.json` persistence for a CI readiness result.

  An assessment is scoped to the repository, base branch and config fingerprint,
  and expires after an hour.
  """

  alias Aiur.{Config, Workflow}
  alias Aiur.GitHub.CiReadiness
  alias Aiur.GitHub.Config, as: GitHubConfig

  # Keyed on the parent module, as before the split.
  @cache_key {CiReadiness, :results}
  @assessment_file_name "ci-readiness.json"
  @assessment_ttl_seconds 3_600

  @doc false
  @spec cache_result(CiReadiness.result(), keyword()) :: :ok
  def cache_result(%{} = result, opts \\ []) do
    scope = cache_scope(result, opts)
    assessed_at = Keyword.get(opts, :now, DateTime.utc_now())
    cache_assessment(scope, %{result: result, assessed_at: assessed_at})
  end

  @doc false
  @spec cached_result(keyword()) :: CiReadiness.result() | :unavailable
  def cached_result(opts \\ []) do
    scope = cache_scope(nil, opts)

    if Keyword.get(opts, :force_refresh, false) do
      delete_cached_scope(scope)
      :unavailable
    else
      read_cached_result(scope, opts)
    end
  end

  defp read_cached_result(scope, opts) do
    memory_assessment =
      case :persistent_term.get(@cache_key, %{}) do
        %{^scope => assessment} -> fresh_assessment(assessment, opts)
        _ -> nil
      end

    case newest_assessment(memory_assessment, load_persisted_assessment(scope, opts)) do
      %{result: result} = assessment ->
        if assessment != memory_assessment, do: cache_assessment(scope, assessment)
        result

      nil ->
        delete_cached_scope(scope)
        :unavailable
    end
  end

  @doc "Persists a non-secret, operator-verified assessment beside the workflow config."
  @spec persist_assessment(CiReadiness.result(), keyword()) :: :ok | {:error, term()}
  def persist_assessment(%{} = result, opts \\ []) do
    scope = cache_scope(result, opts)
    assessed_at = Keyword.get(opts, :now, DateTime.utc_now())

    document = %{
      "version" => 1,
      "assessed_at" => DateTime.to_iso8601(assessed_at),
      "scope" => scope_to_map(scope),
      "result" => encode_result(result)
    }

    path = Keyword.get(opts, :path, assessment_path(Keyword.get(opts, :config_path, Workflow.workflow_file_path())))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(document),
         :ok <- File.write(path, json) do
      cache_assessment(scope, %{result: result, assessed_at: assessed_at})
    end
  end

  @doc false
  @spec clear_cached_result() :: :ok
  def clear_cached_result do
    :persistent_term.erase(@cache_key)
    :ok
  end

  @doc false
  @spec assessment_path() :: Path.t()
  @spec assessment_path(Path.t()) :: Path.t()
  def assessment_path(config_path \\ Workflow.workflow_file_path()), do: Path.join(Path.dirname(config_path), @assessment_file_name)

  @doc false
  @spec readiness_scope(keyword()) :: {String.t(), String.t(), String.t()}
  def readiness_scope(opts \\ []), do: cache_scope(nil, opts)

  defp cache_scope(result, opts) do
    repo = Keyword.get(opts, :repo, GitHubConfig.repo()) || ""

    base_branch = resolve_scope_base_branch(result, opts)

    {repo, base_branch, config_fingerprint(opts)}
  end

  defp resolve_scope_base_branch(result, opts) do
    case Keyword.fetch(opts, :base_branch) do
      {:ok, _branch} -> Config.base_branch(opts)
      :error -> resolve_result_base_branch(result)
    end
  end

  defp resolve_result_base_branch(%{base_branch: _branch} = result), do: Config.base_branch(result)
  defp resolve_result_base_branch(_result), do: Config.base_branch()

  defp config_fingerprint(opts) do
    case Keyword.get(opts, :config_fingerprint) do
      value when is_binary(value) -> value
      _ -> workflow_fingerprint(Keyword.get(opts, :config_path, Workflow.workflow_file_path()))
    end
  end

  defp workflow_fingerprint(path) do
    case File.read(path) do
      {:ok, content} -> :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      {:error, _reason} -> "missing"
    end
  end

  defp scope_to_map({repo, base_branch, fingerprint}) do
    %{"repo" => repo, "base_branch" => base_branch, "config_fingerprint" => fingerprint}
  end

  defp load_persisted_assessment(scope, opts) do
    path = Keyword.get(opts, :path, assessment_path(Keyword.get(opts, :config_path, Workflow.workflow_file_path())))

    with {:ok, body} <- File.read(path),
         {:ok, document} <- Jason.decode(body),
         true <- Map.get(document, "version") == 1,
         ^scope <- map_to_scope(Map.get(document, "scope")),
         {:ok, assessed_at} <- decode_assessed_at(Map.get(document, "assessed_at")),
         true <- assessment_fresh?(assessed_at, opts),
         {:ok, result} <- decode_result(Map.get(document, "result")) do
      %{result: result, assessed_at: assessed_at}
    else
      _ -> nil
    end
  end

  defp fresh_assessment(%{result: %{} = result, assessed_at: %DateTime{} = assessed_at}, opts) do
    if assessment_fresh?(assessed_at, opts), do: %{result: result, assessed_at: assessed_at}
  end

  defp fresh_assessment(_assessment, _opts), do: nil

  defp decode_assessed_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, assessed_at, _offset} -> {:ok, assessed_at}
      _ -> :error
    end
  end

  defp decode_assessed_at(_value), do: :error

  defp newest_assessment(nil, assessment), do: assessment
  defp newest_assessment(assessment, nil), do: assessment

  defp newest_assessment(%{assessed_at: memory_at} = memory, %{assessed_at: persisted_at} = persisted) do
    case DateTime.compare(persisted_at, memory_at) do
      :gt -> persisted
      _ -> memory
    end
  end

  defp cache_assessment(scope, assessment) do
    cached = :persistent_term.get(@cache_key, %{})
    :persistent_term.put(@cache_key, Map.put(cached, scope, assessment))
    :ok
  end

  defp delete_cached_scope(scope) do
    case :persistent_term.get(@cache_key, %{}) do
      %{^scope => _assessment} = cached -> :persistent_term.put(@cache_key, Map.delete(cached, scope))
      _ -> :ok
    end
  end

  defp map_to_scope(%{"repo" => repo, "base_branch" => base_branch, "config_fingerprint" => fingerprint})
       when is_binary(repo) and is_binary(base_branch) and is_binary(fingerprint),
       do: {repo, base_branch, fingerprint}

  defp map_to_scope(_scope), do: :invalid

  defp assessment_fresh?(%DateTime{} = assessed_at, opts) do
    age_seconds = DateTime.diff(Keyword.get(opts, :now, DateTime.utc_now()), assessed_at, :second)
    age_seconds in 0..@assessment_ttl_seconds
  end

  defp encode_result(result) do
    %{
      "ready" => Map.get(result, :ready?),
      "base_branch" => Map.get(result, :base_branch),
      "workflow_paths" => Map.get(result, :workflow_paths, []),
      "workflow_check_names" => Map.get(result, :workflow_check_names, []),
      "required_checks" => Map.get(result, :required_checks, []),
      "required_check_identities" => Map.get(result, :required_check_identities, []),
      "issues" => Enum.map(Map.get(result, :issues, []), &encode_issue/1)
    }
  end

  defp encode_issue(issue) when is_atom(issue), do: Atom.to_string(issue)
  defp encode_issue({:required_check_not_produced, checks}), do: %{"type" => "required_check_not_produced", "checks" => checks}

  defp encode_issue({:required_check_integration_not_produced, checks}),
    do: %{"type" => "required_check_integration_not_produced", "checks" => checks}

  defp encode_issue({:unavailable, reason}), do: %{"type" => "unavailable", "reason" => inspect(reason)}

  defp decode_result(%{"ready" => ready?, "base_branch" => base_branch} = result)
       when is_boolean(ready?) and is_binary(base_branch) do
    with {:ok, issues} <- decode_issues(Map.get(result, "issues", [])) do
      {:ok,
       %{
         ready?: ready?,
         base_branch: base_branch,
         workflow_paths: string_list(Map.get(result, "workflow_paths", [])),
         workflow_check_names: string_list(Map.get(result, "workflow_check_names", [])),
         required_checks: string_list(Map.get(result, "required_checks", [])),
         required_check_identities: check_identities(Map.get(result, "required_check_identities", [])),
         issues: issues
       }}
    end
  end

  defp decode_result(_result), do: :error

  defp decode_issues(issues) when is_list(issues), do: Enum.reduce_while(issues, {:ok, []}, &decode_issue/2)
  defp decode_issues(_issues), do: :error

  defp decode_issue("base_branch_missing", {:ok, acc}), do: {:cont, {:ok, acc ++ [:base_branch_missing]}}
  defp decode_issue("no_pr_workflow", {:ok, acc}), do: {:cont, {:ok, acc ++ [:no_pr_workflow]}}
  defp decode_issue("no_required_check", {:ok, acc}), do: {:cont, {:ok, acc ++ [:no_required_check]}}

  defp decode_issue(%{"type" => "required_check_not_produced", "checks" => checks}, {:ok, acc}) when is_list(checks),
    do: {:cont, {:ok, acc ++ [{:required_check_not_produced, string_list(checks)}]}}

  defp decode_issue(%{"type" => "required_check_integration_not_produced", "checks" => checks}, {:ok, acc}) when is_list(checks),
    do: {:cont, {:ok, acc ++ [{:required_check_integration_not_produced, string_list(checks)}]}}

  defp decode_issue(%{"type" => "unavailable", "reason" => reason}, {:ok, acc}) when is_binary(reason),
    do: {:cont, {:ok, acc ++ [{:unavailable, reason}]}}

  defp decode_issue(_issue, _acc), do: {:halt, :error}

  defp string_list(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp string_list(_values), do: []

  defp check_identities(values) when is_list(values) do
    Enum.flat_map(values, fn
      %{"name" => name, "app_id" => app_id} when is_binary(name) and (is_integer(app_id) or is_nil(app_id)) ->
        [%{name: name, app_id: app_id}]

      %{name: name, app_id: app_id} when is_binary(name) and (is_integer(app_id) or is_nil(app_id)) ->
        [%{name: name, app_id: app_id}]

      _ ->
        []
    end)
  end

  defp check_identities(_values), do: []
end
