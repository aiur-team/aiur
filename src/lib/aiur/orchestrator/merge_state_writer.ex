defmodule Aiur.Orchestrator.MergeStateWriter do
  @moduledoc false

  alias Aiur.GitHub.{Config, Labels, StatePolicy}
  alias Aiur.Issue
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.Tracker

  @spec write_if_current(String.t(), String.t()) :: :ok | :skipped | {:error, term()}
  @spec write_if_current(String.t(), String.t(), keyword()) :: :ok | :skipped | {:error, term()}
  def write_if_current(identifier, target, opts \\ []) do
    fetch_issue_states_fun = Keyword.get(opts, :fetch_issue_states_fun, &Tracker.fetch_issue_states_by_ids/1)
    foreign_state_label_fun = Keyword.get(opts, :foreign_state_label_fun, &Tracker.foreign_state_label?/1)
    tracker = Keyword.get(opts, :tracker, Tracker)

    case fetch_issue_states_fun.([to_string(identifier)]) do
      {:ok, [%Issue{state: state}]} when is_binary(state) ->
        refuse_labels = if StatePolicy.terminal_state_name?(target), do: [], else: operator_hold_labels()

        prefix = Config.label_prefix()

        terminal_labels =
          if StatePolicy.terminal_state_name?(target) do
            clear_terminal_labels(prefix, target) ++ ["#{prefix}:merge-queued", "#{prefix}:body-fix"]
          else
            []
          end

        TicketTransition.write_state(identifier, target,
          writer: :comment_wake,
          expected_state: state,
          refuse_labels: refuse_labels,
          clear_terminal_state_overrides: StatePolicy.terminal_state_name?(target),
          clear_terminal_state_labels: terminal_labels,
          tracker: tracker
        )

      {:ok, [%Issue{labels: labels}]} ->
        if StatePolicy.terminal_state_name?(target) and foreign_state_label_fun.(labels) do
          :skipped
        else
          {:error, :merge_issue_state_unavailable}
        end

      {:ok, _} ->
        {:error, :merge_issue_state_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec clear_nonterminal_merge_queued(String.t(), keyword()) :: :ok | {:error, term()}
  def clear_nonterminal_merge_queued(identifier, opts \\ []) do
    fetch_issue_states_fun = Keyword.get(opts, :fetch_issue_states_fun, &Tracker.fetch_issue_states_by_ids/1)
    tracker = Keyword.get(opts, :tracker, Tracker)
    prefix = Keyword.get(opts, :label_prefix, Config.label_prefix())
    merge_queued = String.downcase("#{prefix}:merge-queued")

    case fetch_issue_states_fun.([to_string(identifier)]) do
      {:ok, [%Issue{labels: labels}]} when is_list(labels) ->
        labels = MapSet.new(Enum.map(labels, &(to_string(&1) |> String.trim() |> String.downcase())))

        has_another_state? =
          Labels.state_labels(prefix)
          |> Enum.map(&String.downcase/1)
          |> Enum.any?(&(&1 != merge_queued and MapSet.member?(labels, &1)))

        if MapSet.member?(labels, merge_queued) and has_another_state? do
          remove_nonterminal_merge_queued(identifier, "#{prefix}:merge-queued", tracker, opts)
        else
          :ok
        end

      {:ok, _issues} ->
        {:error, :merge_issue_labels_unavailable}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_merge_issue_labels, other}}
    end
  end

  defp remove_nonterminal_merge_queued(identifier, label, tracker, opts) do
    case Keyword.get(opts, :remove_merge_queued_label_fun) do
      remove_fun when is_function(remove_fun, 2) ->
        remove_fun.(to_string(identifier), label)

      _other ->
        TicketTransition.write_marker(to_string(identifier), :remove, label, writer: :comment_wake, tracker: tracker)
    end
  end

  @doc false
  @spec write_reconciler_transition(String.t(), String.t(), term(), keyword()) ::
          :ok | {:error, term()}
  def write_reconciler_transition(identifier, target, expected_state, opts) do
    prefix = Config.label_prefix()
    terminal? = StatePolicy.terminal_state_name?(target)

    TicketTransition.write_state(identifier, target,
      writer: :merged_ticket_reconciler,
      expected_state: expected_state,
      refuse_labels: operator_hold_labels(),
      clear_terminal_state_labels: if(terminal?, do: clear_terminal_labels(prefix, target), else: []),
      tracker: Keyword.get(opts, :tracker, Tracker)
    )
  end

  defp clear_terminal_labels(prefix, target),
    do: Labels.state_labels(prefix) -- [StatePolicy.state_label(prefix, target)]

  @doc false
  @spec operator_hold_labels() :: [String.t()]
  def operator_hold_labels do
    prefix = Config.label_prefix()
    ["needs-triage", "human:todo", "#{prefix}:paused", "#{prefix}:parked"]
  end
end
