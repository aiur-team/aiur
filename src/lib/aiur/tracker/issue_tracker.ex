defmodule Aiur.Tracker.IssueTracker do
  @moduledoc "Issue-tracker reads, writes and locally delivered ticket evidence."

  @type open_issue_label_map :: %{String.t() => %{labels: [String.t()], updated_at: DateTime.t() | nil}}
  @type open_issue_labels_result :: {:ok, open_issue_label_map(), integer()} | :none | {:error, :unsupported}

  @type ticket_pull_request_result :: Aiur.Tracker.ticket_pull_request_result()

  @callback with_poll_cycle((-> term())) :: term()
  @callback format_preflight_error(term()) :: String.t()
  @optional_callbacks with_poll_cycle: 1, format_preflight_error: 1

  @callback ticket_pull_request(String.t()) :: ticket_pull_request_result()

  @type issue_closure_result :: {:ok, %{open?: boolean(), state_reason: String.t() | nil}} | {:error, term()}
  @callback issue_closure(String.t(), pos_integer()) :: issue_closure_result()

  @callback blocked_by(String.t()) :: {:ok, [String.t()]} | {:error, term()}

  @callback open_issue_labels(pos_integer()) :: open_issue_labels_result()
  @callback refresh_open_issue_labels() :: :ok | {:error, term()}
  @callback fetch_candidate_issues_conditional(map()) :: {:ok, [term()], map()} | {:error, term()}
  @callback hydrate_blocked_by(Aiur.Issue.t()) :: {:ok, Aiur.Issue.t()} | {:error, term()}
  @callback with_transient_retry((-> term()), keyword()) :: term()
  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()], keyword()) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback foreign_state_label?([String.t()]) :: boolean()
  @callback fetch_issue_states_by_ids_conditional([String.t()], map()) ::
              {:ok, [term()], map()} | {:error, term()} | {:error, term(), map()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback create_issue(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback find_issue(String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  @callback fetch_classified_issue_comments(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback ensure_labels([String.t()]) :: :ok | {:error, term()}
  @callback add_label(String.t(), String.t()) :: :ok | {:error, term()}
  @callback remove_label(String.t(), String.t()) :: :ok | {:error, term()}
  @callback reopen_issue(String.t()) :: :ok | {:error, term()}

  @callback clone_url() :: String.t() | nil
  @callback workspace_repo_segment() :: String.t() | nil

  @callback config_module() :: module()
  @callback code_host() :: module() | nil

  @optional_callbacks clone_url: 0,
                      workspace_repo_segment: 0,
                      config_module: 0,
                      create_issue: 2,
                      find_issue: 2,
                      code_host: 0,
                      fetch_candidate_issues_conditional: 1,
                      hydrate_blocked_by: 1,
                      with_transient_retry: 2,
                      ticket_pull_request: 1,
                      blocked_by: 1,
                      issue_closure: 2,
                      ensure_labels: 1,
                      open_issue_labels: 1,
                      refresh_open_issue_labels: 0,
                      fetch_issue_states_by_ids_conditional: 2,
                      foreign_state_label?: 1,
                      update_issue_state: 3,
                      add_label: 2,
                      remove_label: 2,
                      reopen_issue: 1
end
