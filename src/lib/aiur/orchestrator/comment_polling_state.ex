defmodule Aiur.Orchestrator.CommentPollingState do
  @moduledoc "Adapts orchestrator facts for the comments listener and folds its observations in order."
  alias Aiur.GitHub.Listeners
  alias Aiur.Orchestrator.{ReadyForReviewTransitions, State, TrackerHealth}
  alias Aiur.PrReadyLedgerStore

  @spec input(State.t()) :: Listeners.comment_input()
  def input(%State{} = state) do
    entries = Map.values(state.running)

    titles =
      Enum.reduce(entries, %{}, fn entry, acc ->
        with identifier when is_binary(identifier) and identifier != "" <- Map.get(entry, :identifier),
             %{title: title} when is_binary(title) and title != "" <- Map.get(entry, :issue) do
          Map.put(acc, identifier, title)
        else
          _other -> acc
        end
      end)

    Listeners.comment_input(%{
      running_targets: Enum.map(entries, &Map.get(&1, :identifier)),
      running_titles: titles,
      ownership_key: state.snapshot_key,
      next_github_delay_ms: TrackerHealth.github_next_poll_delay_ms(state)
    })
  end

  @spec start_async(State.t(), keyword()) :: State.t()
  def start_async(state, opts \\ []) do
    Listeners.start_comment_poll(input(state), poll_opts(state, opts))
    state
  end

  @spec request_reconcile(State.t(), map(), keyword()) :: State.t()
  def request_reconcile(state, hint, opts \\ []) do
    Listeners.reconcile_hint(hint, input(state), poll_opts(state, opts))
    state
  end

  @spec apply_outcome(State.t(), map()) :: State.t()
  def apply_outcome(state, outcome) do
    state = fold(state, outcome)
    Listeners.update_backoff(TrackerHealth.github_next_poll_delay_ms(state), completion: outcome.completion, poll_opts: poll_opts(state, []))
    state
  end

  defp poll_opts(state, opts) do
    opts
    |> Keyword.put(:pr_review_seen_at, state.pr_review_seen_at)
    |> Keyword.put(:pr_ready_ledger, state.pr_ready_ledger)
    |> Keyword.put(:load_pr_ready_ledger, &PrReadyLedgerStore.load/0)
    |> Keyword.put(:poll_frozen, state.poll_frozen)
    |> Keyword.put_new(:recipient, self())
  end

  @doc false
  @spec fold(State.t(), map()) :: State.t()
  def fold(%State{} = state, outcome) do
    state =
      Enum.reduce(Map.get(outcome, :connectivity, []), state, fn
        :success, state -> TrackerHealth.note_github_connectivity_success(state, :comments)
        {:failure, reason}, state -> TrackerHealth.note_github_connectivity_failure(state, :comments, reason)
      end)

    state = %{state | pr_review_seen_at: Map.merge(state.pr_review_seen_at, Map.get(outcome, :pr_review_seen_at, %{}))}

    case Map.get(outcome, :pr_draft_observations) do
      observations when is_list(observations) -> ReadyForReviewTransitions.observe(state, observations)
      _other -> state
    end
  end
end
