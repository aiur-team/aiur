defmodule Aiur.GitHub.CiReadiness do
  @moduledoc """
  Inspects whether a GitHub repository can merge the pull requests Aiur opens.

  The result deliberately describes every missing prerequisite rather than
  failing at the first one. Callers can therefore use the same inspection for
  init errors, dispatch warnings, and operator status output.
  """

  alias Aiur.{Config, Workflow}
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.{Errors, Transport}

  @ruleset_page_limit 20
  @workflow_page_limit 20
  @cache_key {__MODULE__, :results}
  @assessment_file_name "ci-readiness.json"
  @assessment_ttl_seconds 3_600
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
          required(:ready?) => boolean(),
          required(:base_branch) => String.t(),
          required(:workflow_paths) => [String.t()],
          required(:workflow_check_names) => [String.t()],
          required(:required_checks) => [String.t()],
          required(:required_check_identities) => [%{name: String.t(), app_id: integer() | nil}],
          optional(:merge_gate) => %{require_last_push_approval?: boolean()},
          required(:issues) => [issue()]
        }

  @spec check(keyword()) :: {:ok, result()} | {:error, term()}
  def check(opts \\ []) do
    with {:ok, {owner, repo}} <- resolve_repo(Keyword.get(opts, :repo)),
         {:ok, token} <- Transport.require_token(opts) do
      base_branch = Config.base_branch(opts)

      request_fun =
        opts
        |> Keyword.get(:request_fun, &Transport.default_request_fun/1)
        |> bounded_request_fun(deadline_at_ms(opts))

      inspect_repository(request_fun, token, owner, repo, base_branch, opts)
    end
  end

  @doc false
  @spec operator_token_env() :: String.t()
  def operator_token_env, do: @operator_token_env

  @doc false
  @spec check_fun() :: (keyword() -> {:ok, result()} | {:error, term()})
  def check_fun do
    Application.get_env(:aiur, :ci_readiness_check_fun, &dispatch_check/1)
  end

  @doc false
  @spec dispatch_check(keyword()) :: {:ok, result()} | {:error, term()}
  def dispatch_check(opts) do
    case cached_result(opts) do
      %{} = result -> {:ok, result}
      :unavailable -> check_workflow_presence(opts)
    end
  end

  defp check_workflow_presence(opts) do
    case check(Keyword.put(opts, :workflow_presence_only, true)) do
      {:error, :ci_readiness_operator_token_required} ->
        {:ok, unavailable(Config.base_branch(opts), :ci_readiness_operator_token_required)}

      result ->
        result
    end
  end

  @doc false
  @spec unavailable(String.t(), term()) :: result()
  def unavailable(base_branch, reason) when is_binary(base_branch), do: result(base_branch, [], [], [], [{:unavailable, reason}])

  @doc false
  @spec cache_result(result(), keyword()) :: :ok
  def cache_result(%{} = result, opts \\ []) do
    scope = cache_scope(result, opts)
    assessed_at = Keyword.get(opts, :now, DateTime.utc_now())
    cache_assessment(scope, %{result: result, assessed_at: assessed_at})
  end

  @doc false
  @spec cached_result(keyword()) :: result() | :unavailable
  def cached_result(opts \\ []) do
    scope = cache_scope(nil, opts)

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
  @spec persist_assessment(result(), keyword()) :: :ok | {:error, term()}
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
    encoded = %{
      "ready" => Map.get(result, :ready?),
      "base_branch" => Map.get(result, :base_branch),
      "workflow_paths" => Map.get(result, :workflow_paths, []),
      "workflow_check_names" => Map.get(result, :workflow_check_names, []),
      "required_checks" => Map.get(result, :required_checks, []),
      "required_check_identities" => Map.get(result, :required_check_identities, []),
      "issues" => Enum.map(Map.get(result, :issues, []), &encode_issue/1)
    }

    if Map.has_key?(result, :merge_gate), do: Map.put(encoded, "merge_gate", result.merge_gate), else: encoded
  end

  defp encode_issue(issue) when is_atom(issue), do: Atom.to_string(issue)
  defp encode_issue({:required_check_not_produced, checks}), do: %{"type" => "required_check_not_produced", "checks" => checks}

  defp encode_issue({:required_check_integration_not_produced, checks}),
    do: %{"type" => "required_check_integration_not_produced", "checks" => checks}

  defp encode_issue({:unavailable, reason}), do: %{"type" => "unavailable", "reason" => inspect(reason)}

  defp decode_result(%{"ready" => ready?, "base_branch" => base_branch} = result)
       when is_boolean(ready?) and is_binary(base_branch) do
    with {:ok, issues} <- decode_issues(Map.get(result, "issues", [])) do
      decoded = %{
        ready?: ready?,
        base_branch: base_branch,
        workflow_paths: string_list(Map.get(result, "workflow_paths", [])),
        workflow_check_names: string_list(Map.get(result, "workflow_check_names", [])),
        required_checks: string_list(Map.get(result, "required_checks", [])),
        required_check_identities: check_identities(Map.get(result, "required_check_identities", [])),
        issues: issues
      }

      {:ok, if(Map.has_key?(result, "merge_gate"), do: Map.put(decoded, :merge_gate, decode_merge_gate(result["merge_gate"])), else: decoded)}
    end
  end

  defp decode_result(_result), do: :error

  defp decode_issues(issues) when is_list(issues), do: Enum.reduce_while(issues, {:ok, []}, &decode_issue/2)
  defp decode_issues(_issues), do: :error

  defp decode_merge_gate(%{"require_last_push_approval?" => value}) when is_boolean(value), do: %{require_last_push_approval?: value}
  defp decode_merge_gate(_value), do: %{require_last_push_approval?: false}

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

    with :ok <- branch_exists?(request_fun, token, "#{base_url}/branches/#{encode_path_component(base_branch)}"),
         {:ok, default_branch} <- fetch_default_branch(request_fun, token, base_url),
         {:ok, entries} <- fetch_list(request_fun, token, "#{base_url}/contents/.github/workflows?ref=#{encode_query_value(base_branch)}") do
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

  defp inspect_workflow_entries(_request_fun, _token, _base_url, _base_branch, _default_branch, _entries, _opts),
    do: {:error, :invalid_workflow_entries}

  defp inspect_full_workflow_entries(request_fun, token, base_url, base_branch, default_branch, entries) do
    with {:ok, workflow_states} <- fetch_workflow_states(request_fun, token, base_url, entries),
         {:ok, workflows} <- fetch_workflows(request_fun, token, entries, workflow_states, base_branch),
         {:ok, {required_checks, merge_gate}} <- fetch_required_checks_for_entries(entries, request_fun, token, base_url, base_branch, default_branch) do
      {:ok, evaluate(base_branch, workflows, required_checks, merge_gate)}
    end
  end

  defp inspect_workflow_presence(request_fun, token, base_branch, entries) do
    workflow_states = Map.new(entries, fn entry -> {Map.get(entry, "path"), true} end)

    with {:ok, workflows} <- fetch_workflows(request_fun, token, entries, workflow_states, base_branch) do
      readiness = evaluate(base_branch, workflows, [])

      if readiness.workflow_paths == [] do
        {:ok, readiness}
      else
        {:error, :ci_readiness_operator_token_required}
      end
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
  @spec evaluate(String.t(), [{String.t(), String.t()}], [String.t() | map()]) :: result()
  def evaluate(base_branch, workflows, required_checks)
      when is_binary(base_branch) and is_list(workflows) and is_list(required_checks) do
    evaluate(base_branch, workflows, required_checks, %{require_last_push_approval?: false}) |> Map.delete(:merge_gate)
  end

  @spec evaluate(String.t(), [{String.t(), String.t()}], [String.t() | map()], map()) :: result()
  def evaluate(base_branch, workflows, required_checks, merge_gate)
      when is_binary(base_branch) and is_list(workflows) and is_list(required_checks) and is_map(merge_gate) do
    pr_workflows = Enum.filter(workflows, fn {_path, source} -> pull_request_workflow?(source, base_branch) end)
    workflow_check_names = pr_workflows |> Enum.flat_map(&workflow_check_names/1) |> Enum.uniq() |> Enum.sort()
    required_check_identities = required_checks |> Enum.map(&required_check_identity/1) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort_by(& &1.name)
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

    result(base_branch, Enum.map(pr_workflows, &elem(&1, 0)), workflow_check_names, required_checks, required_check_identities, merge_gate, issues)
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

  defp fetch_workflow_states(request_fun, token, base_url, entries) do
    if workflow_entries?(entries) do
      fetch_workflow_state_pages(request_fun, token, base_url, "#{base_url}/actions/workflows?per_page=100")
    else
      {:ok, %{}}
    end
  end

  defp fetch_workflow_state_pages(request_fun, token, base_url, url, pages_left \\ @workflow_page_limit, seen \\ [], states \\ %{})

  defp fetch_workflow_state_pages(_request_fun, _token, _base_url, _url, 0, _seen, _states), do: {:error, :workflow_pagination_limit}

  defp fetch_workflow_state_pages(request_fun, token, base_url, url, pages_left, seen, states) do
    if url in seen do
      {:error, :workflow_pagination_cycle}
    else
      fetch_workflow_state_page(request_fun, token, base_url, url, pages_left, seen, states)
    end
  end

  defp fetch_workflow_state_page(request_fun, token, base_url, url, pages_left, seen, states) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: %{"workflows" => workflows}} = response} when is_list(workflows) ->
        states =
          Map.merge(
            states,
            Map.new(workflows, fn workflow -> {Map.get(workflow, "path"), Map.get(workflow, "state") == "active"} end)
          )

        continue_workflow_state_pages(
          Transport.parse_next_page_url(Map.get(response, :headers, %{})),
          request_fun,
          token,
          base_url,
          url,
          pages_left,
          seen,
          states
        )

      {:ok, %{status: _} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}

      _ ->
        {:error, :invalid_workflow_states_response}
    end
  end

  defp continue_workflow_state_pages(nil, _request_fun, _token, _base_url, _url, _pages_left, _seen, states), do: {:ok, states}

  defp continue_workflow_state_pages(next_url, request_fun, token, base_url, url, pages_left, seen, states) do
    if String.starts_with?(next_url, base_url <> "/actions/workflows") do
      fetch_workflow_state_pages(request_fun, token, base_url, next_url, pages_left - 1, [url | seen], states)
    else
      {:error, :invalid_workflow_pagination_url}
    end
  end

  defp fetch_required_checks_for_entries(entries, request_fun, token, base_url, base_branch, default_branch) do
    if Enum.any?(entries, &(Map.get(&1, "type") == "file" and workflow_path?(Map.get(&1, "path", "")))) do
      fetch_required_checks(request_fun, token, base_url, base_branch, default_branch)
    else
      {:ok, {[], %{require_last_push_approval?: false}}}
    end
  end

  defp fetch_workflows(request_fun, token, entries, workflow_states, base_branch) do
    entries
    |> Enum.filter(fn entry ->
      path = Map.get(entry, "path", "")
      Map.get(entry, "type") == "file" and workflow_path?(path) and Map.get(workflow_states, path, false)
    end)
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

  defp workflow_entries?(entries), do: Enum.any?(entries, &(Map.get(&1, "type") == "file" and workflow_path?(Map.get(&1, "path", ""))))

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
    url <> separator <> "ref=#{encode_query_value(base_branch)}"
  end

  defp fetch_required_checks(request_fun, token, base_url, base_branch, default_branch) do
    protection_url = "#{base_url}/branches/#{encode_path_component(base_branch)}/protection"

    with {:ok, protection_checks} <- fetch_protection_checks(request_fun, token, protection_url),
         {:ok, {ruleset_checks, merge_gate}} <- fetch_ruleset_checks(request_fun, token, base_url, base_branch, default_branch) do
      {:ok, {Enum.uniq(protection_checks ++ ruleset_checks), merge_gate}}
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
      {:ok, {rulesets |> Enum.flat_map(&required_checks_from/1) |> Enum.uniq(), merge_gate(rulesets)}}
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
        continue_ruleset_page(
          Transport.parse_next_page_url(Map.get(response, :headers, %{})),
          request_fun,
          token,
          base_url,
          url,
          pages_left,
          seen,
          acc ++ rulesets
        )

      {:ok, %{status: _} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}

      _ ->
        {:error, :invalid_ruleset_response}
    end
  end

  defp continue_ruleset_page(nil, _request_fun, _token, _base_url, _url, _pages_left, _seen, summaries), do: {:ok, summaries}

  defp continue_ruleset_page(next_url, request_fun, token, base_url, url, pages_left, seen, summaries) do
    if String.starts_with?(next_url, base_url <> "/rulesets") do
      fetch_ruleset_summaries(request_fun, token, base_url, next_url, pages_left - 1, [url | seen], summaries)
    else
      {:error, :invalid_ruleset_pagination_url}
    end
  end

  defp fetch_ruleset_details(request_fun, token, base_url, summaries) do
    Enum.reduce_while(summaries, {:ok, []}, fn summary, {:ok, details} ->
      case fetch_ruleset_detail(request_fun, token, base_url, summary) do
        {:ok, detail} -> {:cont, {:ok, [detail | details]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, details} -> {:ok, Enum.reverse(details)}
      error -> error
    end)
  end

  defp fetch_ruleset_detail(request_fun, token, base_url, %{"id" => id}) when is_integer(id) or is_binary(id) do
    case request_fun.(%{method: :get, url: "#{base_url}/rulesets/#{URI.encode(to_string(id))}", token: token}) do
      {:ok, %{status: 200, body: detail}} when is_map(detail) -> {:ok, detail}
      {:ok, %{status: _} = response} -> {:error, Errors.github_status_error(response)}
      {:error, reason} -> {:error, Errors.classify_error({:error, reason})}
      _ -> {:error, :invalid_ruleset_response}
    end
  end

  defp fetch_ruleset_detail(_request_fun, _token, _base_url, _summary), do: {:error, :invalid_ruleset_summary}

  defp required_checks_from(value) when is_map(value) do
    checks =
      value
      |> direct_required_checks()
      |> Enum.map(&required_check_identity/1)

    nested =
      value
      |> Map.get("rules", [])
      |> List.wrap()
      |> Enum.filter(&(Map.get(&1, "type") == "required_status_checks"))
      |> Enum.flat_map(&required_checks_from/1)

    (checks ++ nested) |> Enum.reject(&is_nil/1) |> Enum.uniq()
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

  defp required_check_identity(%{name: name, app_id: app_id}) when is_binary(name) and (is_integer(app_id) or is_nil(app_id)) do
    if valid_name?(name), do: %{name: name, app_id: app_id}
  end

  defp required_check_identity(%{} = item) do
    name = Map.get(item, "context") || Map.get(item, :context)
    app_id = Map.get(item, "app_id") || Map.get(item, :app_id) || Map.get(item, "integration_id") || Map.get(item, :integration_id)

    if valid_name?(name) and (is_integer(app_id) or is_nil(app_id)), do: %{name: name, app_id: app_id}
  end

  defp required_check_identity(name) when is_binary(name) do
    if valid_name?(name), do: %{name: name, app_id: nil}
  end

  defp required_check_identity(_item), do: nil

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
  defp encode_path_component(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp encode_query_value(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp valid_name?(value), do: is_binary(value) and String.trim(value) != ""
  defp maybe_add(issues, true, issue), do: issues ++ [issue]
  defp maybe_add(issues, false, _issue), do: issues

  defp result(base_branch, workflow_paths, workflow_check_names, required_checks, issues),
    do: result(base_branch, workflow_paths, workflow_check_names, required_checks, [], %{require_last_push_approval?: false}, issues)

  defp result(base_branch, workflow_paths, workflow_check_names, required_checks, required_check_identities, merge_gate, issues) do
    %{
      ready?: issues == [],
      base_branch: base_branch,
      workflow_paths: workflow_paths,
      workflow_check_names: workflow_check_names,
      required_checks: required_checks,
      required_check_identities: required_check_identities,
      merge_gate: merge_gate,
      issues: issues
    }
  end

  defp merge_gate(rulesets) do
    %{require_last_push_approval?: Enum.any?(rulesets, &ruleset_requires_last_push_approval?/1)}
  end

  defp ruleset_requires_last_push_approval?(ruleset) do
    ruleset
    |> Map.get("rules", [])
    |> List.wrap()
    |> Enum.any?(fn rule ->
      Map.get(rule, "type") == "pull_request" and
        get_in(rule, ["parameters", "require_last_push_approval"]) == true
    end)
  end

  defp format_issue(:base_branch_missing), do: "configured base branch does not exist"
  defp format_issue(:no_pr_workflow), do: "no workflow triggers on pull_request"
  defp format_issue(:no_required_check), do: "no required status check is configured"
  defp format_issue({:required_check_not_produced, checks}), do: "required check is not produced: #{Enum.join(checks, ", ")}"
  defp format_issue({:required_check_integration_not_produced, checks}), do: "required check is pinned to a different GitHub App: #{Enum.join(checks, ", ")}"
  defp format_issue({:unavailable, reason}), do: "inspection unavailable: #{inspect(reason)}"

  defp format_check_identity(%{name: name, app_id: app_id}), do: "#{name} (app_id: #{app_id})"
end
