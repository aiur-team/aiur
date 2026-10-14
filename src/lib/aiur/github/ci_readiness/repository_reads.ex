defmodule Aiur.GitHub.CiReadiness.RepositoryReads do
  @moduledoc """
  GitHub reads behind a CI readiness inspection: the repository and its default
  branch, workflow files and their enabled state, and the required checks from
  branch protection and rulesets.
  """

  alias Aiur.GitHub.CiReadiness.WorkflowRules
  alias Aiur.GitHub.{Credential, Errors, Transport}

  @ruleset_page_limit 20
  @workflow_page_limit 20
  @plan_limit_message "Upgrade to GitHub Pro or make this repository public"

  @doc false
  @spec fetch_default_branch((map() -> term()), String.t(), String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def fetch_default_branch(request_fun, token, base_url, owner, repo) do
    # #2298 item 5: repo-configuration reads carry `caller: "ci_readiness"` so
    # they are attributed. The bare `/repos/{owner}/{repo}` URL stays
    # unclassified in ReadCache (it is the auth-preflight probe), while the
    # config sub-paths (`/branches/…`, `/contents/.github/workflows`,
    # `/actions/workflows`, `/rulesets`) are classified as `:repo_config`.
    case request(request_fun, %{method: :get, url: base_url, token: token, caller: "ci_readiness"}) do
      {:ok, %{status: 200, body: %{"default_branch" => branch}}} when is_binary(branch) -> {:ok, branch}
      {:ok, %{status: 404} = response} -> classify_repository_not_found(request_fun, token, owner, repo, response)
      {:ok, %{status: _} = response} -> {:error, Errors.github_status_error(response)}
      {:error, reason} -> {:error, Errors.classify_error({:error, reason})}
      _ -> {:error, :invalid_repository_response}
    end
  end

  defp classify_repository_not_found(request_fun, token, owner, repo, repository_response) do
    organization_url = "#{Transport.base_url()}/orgs/#{encode_path_component(owner)}"

    case request(request_fun, %{method: :get, url: organization_url, token: token, caller: "ci_readiness"}) do
      {:ok, %{status: status}} when status in 200..299 ->
        {:error, {:github_org_repository_not_accessible, %{organization: owner, repo: "#{owner}/#{repo}", token_type: Credential.token_type(token)}}}

      {:ok, %{status: 404}} ->
        {:error, Errors.github_status_error(repository_response)}

      {:ok, %{status: _} = response} ->
        organization_error = Errors.github_status_error(response)

        if Errors.retryable_github_error?(organization_error),
          do: {:error, organization_error},
          else: {:error, Errors.github_status_error(repository_response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}

      _ ->
        {:error, :invalid_organization_response}
    end
  end

  @doc false
  @spec branch_exists?((map() -> term()), String.t(), String.t()) :: :ok | {:error, term()}
  def branch_exists?(request_fun, token, url) do
    case request(request_fun, %{method: :get, url: url, token: token, caller: "ci_readiness"}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> {:error, :base_branch_missing}
      {:ok, %{status: _} = response} -> {:error, Errors.github_status_error(response)}
      {:error, reason} -> {:error, Errors.classify_error({:error, reason})}
    end
  end

  @doc false
  @spec fetch_list((map() -> term()), String.t(), String.t()) :: {:ok, list()} | {:error, term()}
  def fetch_list(request_fun, token, url) do
    case request(request_fun, %{method: :get, url: url, token: token, caller: "ci_readiness"}) do
      {:ok, %{status: 200, body: body}} when is_list(body) -> {:ok, body}
      {:ok, %{status: 404}} -> {:ok, []}
      {:ok, %{status: _} = response} -> {:error, Errors.github_status_error(response)}
      {:error, reason} -> {:error, Errors.classify_error({:error, reason})}
    end
  end

  @doc false
  @spec fetch_workflow_states((map() -> term()), String.t(), String.t(), list()) :: {:ok, map()} | {:error, term()}
  def fetch_workflow_states(request_fun, token, base_url, entries) do
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
    case request(request_fun, %{method: :get, url: url, token: token, caller: "ci_readiness"}) do
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

  @doc false
  @spec fetch_required_checks_for_entries(list(), (map() -> term()), String.t(), String.t(), String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_required_checks_for_entries(entries, request_fun, token, base_url, base_branch, default_branch) do
    if Enum.any?(entries, &(Map.get(&1, "type") == "file" and workflow_path?(Map.get(&1, "path", "")))) do
      fetch_required_checks(request_fun, token, base_url, base_branch, default_branch)
    else
      {:ok, []}
    end
  end

  @doc false
  @spec fetch_workflows((map() -> term()), String.t(), list(), map(), String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def fetch_workflows(request_fun, token, entries, workflow_states, base_branch) do
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
    case request(request_fun, %{method: :get, url: workflow_url(entry, base_branch), token: token, caller: "ci_readiness"}) do
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
         {:ok, ruleset_checks} <- fetch_ruleset_checks(request_fun, token, base_url, base_branch, default_branch) do
      {:ok, Enum.uniq(protection_checks ++ ruleset_checks)}
    end
  end

  @doc false
  @spec fetch_protection_checks((map() -> term()), String.t(), String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_protection_checks(request_fun, token, protection_url, caller \\ "ci_readiness") do
    case request(request_fun, %{method: :get, url: protection_url, token: token, caller: caller}) do
      {:ok, %{status: 200, body: protection}} -> {:ok, required_checks_from(protection)}
      {:ok, %{status: 404}} -> {:ok, []}
      {:ok, %{status: _} = response} -> {:error, required_check_error(response)}
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
      rulesets = Enum.filter(rulesets, &WorkflowRules.ruleset_applies?(&1, base_branch, default_branch))
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
    case request(request_fun, %{method: :get, url: url, token: token, caller: "ci_readiness"}) do
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
        {:error, required_check_error(response)}

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
    case request(request_fun, %{method: :get, url: "#{base_url}/rulesets/#{URI.encode(to_string(id))}", token: token, caller: "ci_readiness"}) do
      {:ok, %{status: 200, body: detail}} when is_map(detail) -> {:ok, detail}
      {:ok, %{status: _} = response} -> {:error, required_check_error(response)}
      {:error, reason} -> {:error, Errors.classify_error({:error, reason})}
      _ -> {:error, :invalid_ruleset_response}
    end
  end

  defp fetch_ruleset_detail(_request_fun, _token, _base_url, _summary), do: {:error, :invalid_ruleset_summary}

  defp required_check_error(%{status: 403} = response) do
    case Errors.response_message(response) do
      message when is_binary(message) ->
        if String.contains?(message, @plan_limit_message),
          do: {:ci_readiness_plan_limit, message},
          else: Errors.github_status_error(response)

      _ ->
        Errors.github_status_error(response)
    end
  end

  defp required_check_error(response), do: Errors.github_status_error(response)

  @doc false
  @spec required_checks_from(term()) :: [map()]
  def required_checks_from(value) when is_map(value) do
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

  def required_checks_from(_), do: []

  defp direct_required_checks(value) do
    [
      get_in(value, ["required_status_checks", "contexts"]),
      get_in(value, ["required_status_checks", "checks"]),
      get_in(value, ["parameters", "required_status_checks"])
    ]
    |> Enum.flat_map(&List.wrap/1)
  end

  @doc false
  @spec required_check_identity(term()) :: %{name: String.t(), app_id: integer() | nil} | nil
  def required_check_identity(%{name: name, app_id: app_id}) when is_binary(name) and (is_integer(app_id) or is_nil(app_id)) do
    if WorkflowRules.valid_name?(name), do: %{name: name, app_id: app_id}
  end

  def required_check_identity(%{} = item) do
    name = Map.get(item, "context") || Map.get(item, :context)
    app_id = Map.get(item, "app_id") || Map.get(item, :app_id) || Map.get(item, "integration_id") || Map.get(item, :integration_id)

    if WorkflowRules.valid_name?(name) and (is_integer(app_id) or is_nil(app_id)), do: %{name: name, app_id: app_id}
  end

  def required_check_identity(name) when is_binary(name) do
    if WorkflowRules.valid_name?(name), do: %{name: name, app_id: nil}
  end

  def required_check_identity(_item), do: nil

  defp workflow_path?(path), do: String.ends_with?(path, ".yml") or String.ends_with?(path, ".yaml")

  @doc false
  @spec encode_path_component(String.t()) :: String.t()
  def encode_path_component(value), do: URI.encode(value, &URI.char_unreserved?/1)

  @doc false
  @spec encode_query_value(String.t()) :: String.t()
  def encode_query_value(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp request(request_fun, request), do: request_fun.(Map.put(request, :credential_pinned?, true))
end
