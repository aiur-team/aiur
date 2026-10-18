defmodule Aiur.Orchestrator.CommentPollingState do
  @moduledoc "Adapts the in-place comment poll to State and folds lifecycle observations in order."
  alias Aiur.Orchestrator.{CommentPolling, ReadyForReviewTransitions, State, TrackerHealth}
  alias Aiur.PrReadyLedgerStore

  @spec poll_github_comments(State.t(), keyword()) :: State.t()
  def poll_github_comments(state, opts \\ []), do: run(state, :poll_github_comments, [], opts) |> elem(0)
  @spec start_async(State.t(), keyword()) :: State.t()
  def start_async(state, opts \\ []), do: run(state, :start_async, [], opts) |> elem(0)
  @spec request_reconcile(State.t(), map(), keyword()) :: State.t()
  def request_reconcile(state, hint, opts \\ []), do: run(state, :request_reconcile, [hint], opts) |> elem(0)
  @spec apply_async(State.t(), reference(), term(), keyword()) :: State.t()
  def apply_async(state, ref, payload, opts \\ []), do: run(state, :apply_async, [ref, payload], opts) |> elem(0)
  @spec apply_async_started(State.t(), reference(), pid(), pid(), keyword()) :: State.t()
  def apply_async_started(state, ref, owner, pid, opts \\ []), do: run(state, :apply_async_started, [ref, owner, pid], opts) |> elem(0)
  @spec apply_async_guarding(State.t(), reference(), pid(), pid(), keyword()) :: State.t()
  def apply_async_guarding(state, ref, owner, pid, opts \\ []), do: run(state, :apply_async_guarding, [ref, owner, pid], opts) |> elem(0)
  @spec run_scheduled_reconcile(State.t(), reference(), keyword()) :: State.t()
  def run_scheduled_reconcile(state, token, opts \\ []), do: run(state, :run_scheduled_reconcile, [token], opts) |> elem(0)

  @spec apply_async_down(State.t(), reference()) :: {:handled, State.t()} | :unhandled
  def apply_async_down(%State{} = state, ref) do
    {state, outcome} = run(state, :apply_async_down, [ref], [])
    if outcome.handled?, do: {:handled, state}, else: :unhandled
  end

  @spec terminate_poll(map() | nil) :: :ok
  defdelegate terminate_poll(poll), to: CommentPolling
  @spec reconcile_retry_delay_ms(State.t()) :: non_neg_integer()
  def reconcile_retry_delay_ms(state), do: CommentPolling.reconcile_retry_delay_ms(CommentPolling.input(state))

  defp run(state, function, args, opts) do
    opts =
      opts
      |> Keyword.put(:pr_review_seen_at, state.pr_review_seen_at)
      |> Keyword.put(:pr_ready_ledger, state.pr_ready_ledger)
      |> Keyword.put(:load_pr_ready_ledger, &PrReadyLedgerStore.load/0)
      |> Keyword.put(:poll_frozen, state.poll_frozen)

    {cursor, outcome} = apply(CommentPolling, function, [state.github_comment_cursor, CommentPolling.input(state)] ++ args ++ [opts])
    state = fold(%{state | github_comment_cursor: cursor}, outcome)

    # Connectivity changes the retry delay; finish against the freshly folded State.
    cursor = CommentPolling.finish(cursor, CommentPolling.input(state), outcome, opts)
    state = %{state | github_comment_cursor: cursor}

    {state, outcome}
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
