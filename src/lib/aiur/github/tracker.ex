defmodule Aiur.GitHub.Tracker do
  @moduledoc """
  GitHub-backed tracker implementation.
  """

  @behaviour Aiur.Tracker

  alias Aiur.GitHub.Client
  alias Aiur.GitHub.Config

  @spec project_identity() :: String.t() | nil
  def project_identity, do: Config.repo()

  @spec default_prompt_template() :: String.t()
  def default_prompt_template do
    """
    You are working on a GitHub issue.

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

  @spec auth_preflight() :: :ok | {:error, term()}
  def auth_preflight do
    client = client_module()

    cond do
      function_exported?(client, :preflight_auth, 0) -> client.preflight_auth()
      function_exported?(client, :preflight_auth, 1) -> client.preflight_auth([])
      true -> :ok
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states, opts), do: client_module().fetch_issues_by_states(states, opts)

  @spec fetch_issues_by_states_conditional([String.t()], map()) ::
          {:ok, [term()], map()} | {:error, term()}
  def fetch_issues_by_states_conditional(states, cache) do
    client = client_module()

    if function_exported?(client, :fetch_issues_by_states_conditional, 2) do
      client.fetch_issues_by_states_conditional(states, cache)
    else
      with {:ok, issues} <- client.fetch_issues_by_states(states), do: {:ok, issues, cache}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids),
    do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    client_module().create_comment(issue_id, body)
  end

  @spec fetch_classified_pr_review_comments(String.t() | integer()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_classified_pr_review_comments(pr_number) do
    client_module().fetch_classified_pr_review_comments(pr_number)
  end

  @spec fetch_unaddressed_pr_review_thread_comments(String.t() | integer()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_unaddressed_pr_review_thread_comments(pr_number) do
    client_module().fetch_unaddressed_pr_review_thread_comments(pr_number)
  end

  @spec fetch_classified_issue_comments(String.t() | integer()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_classified_issue_comments(issue_id) do
    client_module().fetch_classified_issue_comments(issue_id)
  end

  @spec fetch_open_pull_request_for_branch(String.t() | integer()) ::
          {:ok, map() | nil} | {:error, term()}
  def fetch_open_pull_request_for_branch(issue_id) do
    client_module().fetch_open_pull_request_for_branch(issue_id)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    client_module().update_issue_state(issue_id, state_name)
  end

  @spec update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name, opts)
      when is_binary(issue_id) and is_binary(state_name) and is_list(opts) do
    client = client_module()

    cond do
      Code.ensure_loaded?(client) and function_exported?(client, :update_issue_state, 3) ->
        client.update_issue_state(issue_id, state_name, opts)

      opts == [] ->
        client.update_issue_state(issue_id, state_name)

      true ->
        {:error, :expected_state_unsupported}
    end
  end

  @spec add_label(String.t(), String.t()) :: :ok | {:error, term()}
  def add_label(issue_id, label) when is_binary(issue_id) and is_binary(label) do
    client_module().add_label(issue_id, label)
  end

  @spec remove_label(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_label(issue_id, label) when is_binary(issue_id) and is_binary(label) do
    client_module().remove_label(issue_id, label)
  end

  defp client_module do
    Application.get_env(:aiur, :github_client_module, Client)
  end
end
