defmodule Aiur.Tracker.IssueTracker do
  @moduledoc "Issue-tracker reads, writes and locally delivered ticket evidence."

  @type open_issue_label_map :: %{String.t() => %{labels: [String.t()], updated_at: DateTime.t() | nil}}
  @type open_issue_labels_result :: {:ok, open_issue_label_map(), integer()} | :none | {:error, :unsupported}

  @type ticket_pull_request_result :: Aiur.Tracker.ticket_pull_request_result()

  @callback ticket_pull_request(String.t()) :: ticket_pull_request_result()

  @type issue_closure_result :: {:ok, %{open?: boolean(), state_reason: String.t() | nil}} | {:error, term()}
  @callback issue_closure(String.t(), pos_integer()) :: issue_closure_result()

  @callback blocked_by(String.t()) :: {:ok, [String.t()]} | {:error, term()}

  @callback open_issue_labels(pos_integer()) :: open_issue_labels_result()
  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()], keyword()) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids_conditional([String.t()], map()) ::
              {:ok, [term()], map()} | {:error, term()} | {:error, term(), map()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback fetch_classified_issue_comments(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback ensure_labels([String.t()]) :: :ok | {:error, term()}
  @callback add_label(String.t(), String.t()) :: :ok | {:error, term()}
  @callback remove_label(String.t(), String.t()) :: :ok | {:error, term()}

  @callback config_module() :: module()
  @callback code_host() :: module() | nil

  @optional_callbacks config_module: 0,
                      code_host: 0,
                      ticket_pull_request: 1,
                      blocked_by: 1,
                      issue_closure: 2,
                      ensure_labels: 1,
                      open_issue_labels: 1,
                      fetch_issue_states_by_ids_conditional: 2,
                      update_issue_state: 3,
                      add_label: 2,
                      remove_label: 2
end
