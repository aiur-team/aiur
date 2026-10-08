defmodule Aiur.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias Aiur.{Config, TestTicketScope}

  @type open_issue_label_map :: %{String.t() => %{labels: [String.t()], updated_at: DateTime.t() | nil}}
  @type open_issue_labels_result :: {:ok, open_issue_label_map(), integer()} | :none | {:error, :unsupported}

  @callback open_issue_labels(pos_integer()) :: open_issue_labels_result()
  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()], keyword()) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids_conditional([String.t()], map()) ::
              {:ok, [term()], map()} | {:error, term()} | {:error, term(), map()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback fetch_classified_issue_comments(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_classified_pr_review_comments(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_classified_pr_reviews(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_unaddressed_pr_review_thread_comments(String.t() | integer()) ::
              {:ok, [map()]} | {:error, term()}
  @callback fetch_open_pull_request_for_branch(String.t() | integer()) ::
              {:ok, map() | nil} | {:error, term()}
  @callback fetch_open_pull_requests_for_branch(String.t() | integer()) ::
              {:ok, [map()]} | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback add_label(String.t(), String.t()) :: :ok | {:error, term()}
  @callback remove_label(String.t(), String.t()) :: :ok | {:error, term()}

  @optional_callbacks open_issue_labels: 1,
                      fetch_issue_states_by_ids_conditional: 2,
                      update_issue_state: 3,
                      add_label: 2,
                      remove_label: 2

  @doc "Reads open-issue labels already observed by the tracker, without a remote request."
  @spec open_issue_labels(pos_integer()) :: open_issue_labels_result()
  def open_issue_labels(max_age_ms) do
    tracker_adapter = adapter()

    if Code.ensure_loaded?(tracker_adapter) and function_exported?(tracker_adapter, :open_issue_labels, 1) do
      tracker_adapter.open_issue_labels(max_age_ms)
    else
      {:error, :unsupported}
    end
  end

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues() |> TestTicketScope.filter_result()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states) |> TestTicketScope.filter_result()
  end

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states, opts) do
    adapter().fetch_issues_by_states(states, opts) |> TestTicketScope.filter_result()
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids) |> TestTicketScope.filter_result()
  end

  @spec fetch_issue_states_by_ids_conditional([String.t()], map()) ::
          {:ok, [term()], map()} | {:error, term()} | {:error, term(), map()}
  def fetch_issue_states_by_ids_conditional(issue_ids, cache) do
    tracker_adapter = adapter()

    if Code.ensure_loaded?(tracker_adapter) and
         function_exported?(tracker_adapter, :fetch_issue_states_by_ids_conditional, 2) do
      dispatch_fetch_issue_states_by_ids_conditional(tracker_adapter, issue_ids, cache)
      |> TestTicketScope.filter_result()
    else
      with {:ok, issues} <- tracker_adapter.fetch_issue_states_by_ids(issue_ids),
           do: TestTicketScope.filter_result({:ok, issues, cache})
    end
  end

  @spec dispatch_fetch_issue_states_by_ids_conditional(module(), [String.t()], map()) ::
          {:ok, [term()], map()} | {:error, term()} | {:error, term(), map()}
  defp dispatch_fetch_issue_states_by_ids_conditional(tracker_adapter, issue_ids, cache) do
    tracker_adapter.fetch_issue_states_by_ids_conditional(issue_ids, cache)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name, opts)
      when is_binary(issue_id) and is_binary(state_name) and is_list(opts) do
    tracker_adapter = adapter()

    cond do
      Code.ensure_loaded?(tracker_adapter) and
          function_exported?(tracker_adapter, :update_issue_state, 3) ->
        dispatch_update_issue_state(tracker_adapter, issue_id, state_name, opts)

      opts == [] ->
        tracker_adapter.update_issue_state(issue_id, state_name)

      true ->
        {:error, :expected_state_unsupported}
    end
  end

  @spec dispatch_update_issue_state(module(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  defp dispatch_update_issue_state(tracker_adapter, issue_id, state_name, opts) do
    tracker_adapter.update_issue_state(issue_id, state_name, opts)
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

  @spec fetch_classified_pr_reviews(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  def fetch_classified_pr_reviews(pr_number) do
    adapter().fetch_classified_pr_reviews(pr_number)
  end

  @spec fetch_unaddressed_pr_review_thread_comments(String.t() | integer()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_unaddressed_pr_review_thread_comments(pr_number) do
    adapter().fetch_unaddressed_pr_review_thread_comments(pr_number)
  end

  @spec fetch_open_pull_request_for_branch(String.t() | integer()) ::
          {:ok, map() | nil} | {:error, term()}
  def fetch_open_pull_request_for_branch(issue_id) do
    adapter().fetch_open_pull_request_for_branch(issue_id)
  end

  @spec fetch_open_pull_requests_for_branch(String.t() | integer()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_open_pull_requests_for_branch(issue_id) do
    adapter().fetch_open_pull_requests_for_branch(issue_id)
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
