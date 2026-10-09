defmodule Aiur.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias Aiur.{Config, TestTicketScope}

  @type open_issue_label_map :: %{String.t() => %{labels: [String.t()], updated_at: DateTime.t() | nil}}
  @type open_issue_labels_result :: {:ok, open_issue_label_map(), integer()} | :none | {:error, :unsupported}
  @type ticket_pull_request_result ::
          {:ok, nil | %{required(:state) => :open | :closed, required(:merged?) => boolean(), optional(:number) => pos_integer(), optional(:version) => String.t() | nil}} | {:error, term()}
  @type issue_closure_result :: {:ok, %{open?: boolean(), state_reason: String.t() | nil}} | {:error, term()}

  @doc "Reads native prerequisite IDs, failing closed on unsupported trackers."
  @spec blocked_by(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def blocked_by(issue_id) do
    tracker = adapter()
    if Code.ensure_loaded?(tracker) and function_exported?(tracker, :blocked_by, 1), do: dispatch_blocked_by(tracker, issue_id), else: {:error, :unsupported}
  end

  defp dispatch_blocked_by(tracker, issue_id), do: tracker.blocked_by(issue_id)

  @doc "Reads closure evidence, failing closed when the tracker does not support it."
  @spec issue_closure(String.t(), pos_integer()) :: issue_closure_result()
  def issue_closure(issue_id, max_age_ms) do
    tracker = adapter()
    if Code.ensure_loaded?(tracker) and function_exported?(tracker, :issue_closure, 2), do: tracker.issue_closure(issue_id, max_age_ms), else: {:error, :unsupported}
  end

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

  @doc "Reads a ticket's delivered PR evidence without a remote request; unsupported adapters return nil."
  @spec ticket_pull_request(String.t()) :: ticket_pull_request_result()
  def ticket_pull_request(issue_id) do
    tracker = adapter()
    if Code.ensure_loaded?(tracker) and function_exported?(tracker, :ticket_pull_request, 1), do: tracker.ticket_pull_request(issue_id), else: {:ok, nil}
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

  @spec update_issue_state(String.t(), String.t(), expected_state: String.t() | :none) :: :ok | {:error, term()}
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

  @spec ensure_labels([String.t()]) :: :ok | {:error, term()}
  def ensure_labels(labels) do
    tracker = adapter()
    if Code.ensure_loaded?(tracker) and function_exported?(tracker, :ensure_labels, 1), do: tracker.ensure_labels(labels), else: {:error, :unsupported}
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
  @deprecated "Use Aiur.CodeHost.fetch_classified_pr_review_comments/1"
  def fetch_classified_pr_review_comments(pr_number), do: Aiur.CodeHost.fetch_classified_pr_review_comments(pr_number)

  @spec fetch_classified_pr_reviews(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  @deprecated "Use Aiur.CodeHost.fetch_classified_pr_reviews/1"
  def fetch_classified_pr_reviews(pr_number), do: Aiur.CodeHost.fetch_classified_pr_reviews(pr_number)

  @spec fetch_unaddressed_pr_review_thread_comments(String.t() | integer()) ::
          {:ok, [map()]} | {:error, term()}
  @deprecated "Use Aiur.CodeHost.fetch_unaddressed_pr_review_thread_comments/1"
  def fetch_unaddressed_pr_review_thread_comments(pr_number), do: Aiur.CodeHost.fetch_unaddressed_pr_review_thread_comments(pr_number)

  @spec fetch_open_pull_request_for_branch(String.t() | integer()) ::
          {:ok, map() | nil} | {:error, term()}
  @deprecated "Use Aiur.CodeHost.fetch_open_pull_request_for_branch/1"
  def fetch_open_pull_request_for_branch(issue_id), do: Aiur.CodeHost.fetch_open_pull_request_for_branch(issue_id)

  @spec fetch_open_pull_requests_for_branch(String.t() | integer()) ::
          {:ok, [map()]} | {:error, term()}
  @deprecated "Use Aiur.CodeHost.fetch_open_pull_requests_for_branch/1"
  def fetch_open_pull_requests_for_branch(issue_id), do: Aiur.CodeHost.fetch_open_pull_requests_for_branch(issue_id)

  @spec project_identity() :: String.t() | nil
  def project_identity do
    tracker_adapter = adapter()

    if Code.ensure_loaded?(tracker_adapter) and function_exported?(tracker_adapter, :project_identity, 0) do
      tracker_adapter.project_identity()
    end
  end

  @spec adapter() :: module()
  def adapter do
    Aiur.Tracker.Registry.adapter_for(Config.settings!().tracker.kind)
  end
end
