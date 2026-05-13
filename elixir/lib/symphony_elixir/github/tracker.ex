defmodule SymphonyElixir.GitHub.Tracker do
  @moduledoc """
  GitHub-backed tracker implementation.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.GitHub.Config

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

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    client_module().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    client_module().update_issue_state(issue_id, state_name)
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end
end
