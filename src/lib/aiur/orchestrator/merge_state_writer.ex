defmodule Aiur.Orchestrator.MergeStateWriter do
  @moduledoc false

  alias Aiur.GitHub.Config
  alias Aiur.Issue
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.Tracker

  @spec write_if_current(String.t(), String.t()) :: :ok | {:error, term()}
  @spec write_if_current(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def write_if_current(identifier, target, opts \\ []) do
    fetch_issue_states_fun = Keyword.get(opts, :fetch_issue_states_fun, &Tracker.fetch_issue_states_by_ids/1)
    tracker = Keyword.get(opts, :tracker, Tracker)

    case fetch_issue_states_fun.([to_string(identifier)]) do
      {:ok, [%Issue{state: state}]} when is_binary(state) ->
        TicketTransition.write_state(identifier, target,
          writer: :comment_wake,
          expected_state: state,
          refuse_labels: operator_hold_labels(),
          tracker: tracker
        )

      {:ok, _} ->
        {:error, :merge_issue_state_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec write_reconciler_transition(String.t(), String.t(), term(), keyword()) ::
          :ok | {:error, term()}
  def write_reconciler_transition(identifier, target, expected_state, opts) do
    TicketTransition.write_state(identifier, target,
      writer: :merged_ticket_reconciler,
      expected_state: expected_state,
      refuse_labels: operator_hold_labels(),
      tracker: Keyword.get(opts, :tracker, Tracker)
    )
  end

  @doc false
  @spec operator_hold_labels() :: [String.t()]
  def operator_hold_labels do
    prefix = Config.label_prefix()
    ["needs-triage", "human:todo", "#{prefix}:paused", "#{prefix}:parked"]
  end
end
