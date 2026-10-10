defmodule Aiur.Memory.Tracker do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour Aiur.Tracker.IssueTracker

  @spec config_module() :: module()
  def config_module, do: Aiur.Memory.Config

  alias Aiur.Issue

  @spec blocked_by(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def blocked_by(issue_id) do
    case Enum.find(issue_entries(), &matching_issue?(&1, issue_id)) do
      nil -> {:error, :issue_not_found}
      issue -> {:ok, Enum.map(issue.blocked_by, & &1.id)}
    end
  end

  @spec ticket_pull_request(String.t()) :: Aiur.Tracker.ticket_pull_request_result()
  def ticket_pull_request(_issue_id), do: {:ok, nil}

  @spec open_issue_labels(pos_integer()) :: Aiur.Tracker.open_issue_labels_result()
  def open_issue_labels(_max_age_ms) do
    labels = Map.new(issue_entries(), &{&1.id, %{labels: &1.labels, updated_at: &1.updated_at}})
    {:ok, labels, System.system_time(:millisecond)}
  end

  @spec issue_closure(String.t(), pos_integer()) :: Aiur.Tracker.issue_closure_result()
  def issue_closure(_issue_id, _max_age_ms), do: {:error, :unsupported}

  @spec project_identity() :: String.t() | nil
  def project_identity, do: "memory"

  @spec default_prompt_template() :: String.t()
  def default_prompt_template do
    """
    You are working on an issue.

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

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, issue_entries()}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    fetch_issues_by_states(state_names, [])
  end

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, _opts) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  @spec fetch_classified_issue_comments(String.t() | integer()) :: {:ok, [map()]}
  def fetch_classified_issue_comments(_issue_id), do: {:ok, []}

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  @spec update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name, opts)
      when is_binary(issue_id) and is_binary(state_name) and is_list(opts) do
    case Keyword.fetch(opts, :expected_state) do
      :error ->
        update_issue_state(issue_id, state_name)

      {:ok, expected_state} when is_binary(expected_state) or expected_state == :none ->
        update_issue_state_if_current(issue_id, state_name, expected_state)

      {:ok, _invalid} ->
        {:error, :invalid_expected_state}
    end
  end

  @spec ensure_labels([String.t()]) :: :ok | {:error, term()}
  def ensure_labels(_labels), do: :ok

  @spec add_label(String.t(), String.t()) :: :ok | {:error, term()}
  def add_label(issue_id, label) do
    send_event({:memory_tracker_add_label, issue_id, label})
    :ok
  end

  @spec remove_label(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_label(issue_id, label) do
    remove_configured_label(issue_id, label)
    send_event({:memory_tracker_remove_label, issue_id, label})
    :ok
  end

  defp remove_configured_label(issue_id, label) do
    issues =
      Enum.map(configured_issues(), fn
        %Issue{} = issue -> remove_issue_label(issue, issue_id, label)
        other -> other
      end)

    Application.put_env(:aiur, :memory_tracker_issues, issues)
  end

  defp update_issue_state_if_current(issue_id, state_name, expected_state) do
    issues = configured_issues()

    case Enum.find_index(issues, &matching_issue?(&1, issue_id)) do
      nil ->
        {:error, :issue_not_found}

      index ->
        %Issue{state: current_state} = Enum.at(issues, index)
        expected = if expected_state == :none, do: :none, else: normalize_state_slug(expected_state)
        actual = normalize_state_slug(current_state)

        if actual == expected or (expected == :none and actual == "") do
          Application.put_env(:aiur, :memory_tracker_issues, List.update_at(issues, index, &%{&1 | state: state_name}))
          send_event({:memory_tracker_state_update, issue_id, state_name})
          :ok
        else
          {:error, {:stale_issue_state, expected, actual}}
        end
    end
  end

  defp matching_issue?(%Issue{} = issue, issue_id) do
    Issue.identifier_matches?(issue.id, issue.identifier, issue_id)
  end

  defp matching_issue?(_issue, _issue_id), do: false

  defp remove_issue_label(issue, issue_id, label) do
    if Issue.identifier_matches?(issue.id, issue.identifier, issue_id) do
      labels = Enum.reject(issue.labels, &(&1 == label))
      %{issue | labels: labels, paused: issue.paused and not String.ends_with?(label, ":paused")}
    else
      issue
    end
  end

  defp configured_issues do
    Application.get_env(:aiur, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp send_event(message) do
    case Application.get_env(:aiur, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""

  defp normalize_state_slug(state) do
    state
    |> normalize_state()
    |> String.replace(~r/[\s_]+/, "-")
  end
end
