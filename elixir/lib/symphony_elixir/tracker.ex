defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config

  @callback project_identity() :: String.t() | nil
  @callback default_prompt_template() :: String.t()
  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}

  @spec project_identity() :: String.t() | nil
  def project_identity, do: adapter().project_identity()

  @spec default_prompt_template() :: String.t()
  def default_prompt_template, do: adapter().default_prompt_template()

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
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

  @spec adapter() :: module()
  def adapter do
    case Config.tracker_kind() do
      "memory" -> SymphonyElixir.Memory.Tracker
      "linear" -> SymphonyElixir.Linear.Tracker
      _ -> SymphonyElixir.GitHub.Tracker
    end
  end
end
