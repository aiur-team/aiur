defmodule Aiur.Linear.Tracker do
  @moduledoc """
  Linear-backed tracker implementation.
  """

  @behaviour Aiur.Tracker

  alias Aiur.Linear.Client
  alias Aiur.Linear.Config

  @create_comment_mutation """
  mutation AiurCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation AiurUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query AiurResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      state {
        name
      }
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec project_identity() :: String.t() | nil
  def project_identity, do: Config.project_slug()

  @spec default_prompt_template() :: String.t()
  def default_prompt_template do
    """
    You are working on a Linear issue.

    Identifier: {{ issue.identifier }}
    Title: {{ issue.title }}

    Body:
    {% if issue.description %}
    {{ issue.description }}
    {% else %}
    No description provided.
    {% endif %}
    """
  end

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states, opts), do: client_module().fetch_issues_by_states(states, opts)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec fetch_classified_issue_comments(String.t() | integer()) :: {:ok, [map()]}
  def fetch_classified_issue_comments(_issue_id), do: {:ok, []}

  @spec fetch_classified_pr_review_comments(String.t() | integer()) :: {:ok, [map()]}
  def fetch_classified_pr_review_comments(_pr_number), do: {:ok, []}

  @spec fetch_unaddressed_pr_review_thread_comments(String.t() | integer()) :: {:ok, [map()]}
  def fetch_unaddressed_pr_review_thread_comments(_pr_number), do: {:ok, []}

  @spec fetch_open_pull_request_for_branch(String.t() | integer()) :: {:ok, nil}
  def fetch_open_pull_request_for_branch(_issue_id), do: {:ok, nil}

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name, opts)
      when is_binary(issue_id) and is_binary(state_name) and is_list(opts) do
    case Keyword.fetch(opts, :expected_state) do
      :error ->
        update_issue_state(issue_id, state_name)

      {:ok, expected_state} when is_binary(expected_state) ->
        update_issue_state_if_current(issue_id, state_name, expected_state)

      {:ok, _invalid} ->
        {:error, :invalid_expected_state}
    end
  end

  # The `model:remote` promote/demote toggle is a GitHub-label concept;
  # Linear has no equivalent label op wired here.
  @spec add_label(String.t(), String.t()) :: {:error, term()}
  def add_label(_issue_id, _label), do: {:error, :unsupported}

  @spec remove_label(String.t(), String.t()) :: {:error, term()}
  def remove_label(_issue_id, _label), do: {:error, :unsupported}

  defp client_module do
    Application.get_env(:aiur, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp update_issue_state_if_current(issue_id, state_name, expected_state) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         {:ok, state_id, current_state} <- resolved_state(response),
         :ok <- validate_expected_state(expected_state, current_state),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp resolved_state(response) do
    state_id = get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"])
    current_state = get_in(response, ["data", "issue", "state", "name"])

    if is_binary(state_id) and is_binary(current_state) do
      {:ok, state_id, current_state}
    else
      {:error, :state_not_found}
    end
  end

  defp validate_expected_state(expected_state, current_state) do
    expected = normalize_state(expected_state)
    actual = normalize_state(current_state)

    if actual == expected, do: :ok, else: {:error, {:stale_issue_state, expected, actual}}
  end

  defp normalize_state(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s_]+/, "-")
  end
end
