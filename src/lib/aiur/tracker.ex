defmodule Aiur.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias Aiur.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()], keyword()) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback fetch_classified_issue_comments(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_classified_pr_review_comments(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_open_pull_request_for_branch(String.t() | integer()) ::
              {:ok, map() | nil} | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback add_label(String.t(), String.t()) :: :ok | {:error, term()}
  @callback remove_label(String.t(), String.t()) :: :ok | {:error, term()}

  @optional_callbacks add_label: 2, remove_label: 2

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states, opts) do
    adapter().fetch_issues_by_states(states, opts)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec add_label(String.t(), String.t()) :: :ok | {:error, term()}
  def add_label(issue_id, label) do
    adapter().add_label(issue_id, label)
  end

  @spec remove_label(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_label(issue_id, label) do
    adapter().remove_label(issue_id, label)
  end

  @spec fetch_classified_issue_comments(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  def fetch_classified_issue_comments(issue_id) do
    adapter().fetch_classified_issue_comments(issue_id)
  end

  @spec fetch_classified_pr_review_comments(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  def fetch_classified_pr_review_comments(pr_number) do
    adapter().fetch_classified_pr_review_comments(pr_number)
  end

  @spec fetch_open_pull_request_for_branch(String.t() | integer()) ::
          {:ok, map() | nil} | {:error, term()}
  def fetch_open_pull_request_for_branch(issue_id) do
    adapter().fetch_open_pull_request_for_branch(issue_id)
  end

  @spec project_identity() :: String.t() | nil
  def project_identity do
    tracker_adapter = adapter()

    if Code.ensure_loaded?(tracker_adapter) and function_exported?(tracker_adapter, :project_identity, 0) do
      tracker_adapter.project_identity()
    end
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "github" -> Aiur.GitHub.Tracker
      "memory" -> Aiur.Memory.Tracker
      _ -> Aiur.Linear.Tracker
    end
  end
end
