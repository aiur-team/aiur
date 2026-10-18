defmodule Aiur.Orchestrator.CommentPolling.Reconcile do
  @moduledoc false
  alias Aiur.Orchestrator.CommentPolling.{Cursor, Input}

  @spec reclaim(Cursor.t(), map() | nil) :: Cursor.t()
  def reclaim(state, %{reconcile_targets: targets}) do
    admit(state, targets, [])
  end

  def reclaim(state, _poll), do: state

  @spec requeue(Cursor.t(), MapSet.t()) :: Cursor.t()
  def requeue(state, targets) do
    admit(state, targets, [])
  end

  @spec admit(Cursor.t(), MapSet.t(), keyword()) :: Cursor.t()
  def admit(state, targets, _opts) do
    # Admission is lossless and deduplicated by ticket identity. The bounded
    # claim in TargetSelection limits every GraphQL batch; keeping the remainder
    # here is what lets successive claims drain a burst without pretending an
    # unrelated capped discovery sweep can reconstruct the dropped identities.
    %{state | reconcile_targets: MapSet.union(state.reconcile_targets, targets)}
  end

  @spec failed_targets(map() | nil, term()) :: MapSet.t()
  def failed_targets(%{reconcile_targets: targets}, {:error, _reason}), do: targets

  def failed_targets(
        %{reconcile_targets: targets},
        {:ok, _cache, _human_review_targets, {_polled_targets, {:ok, %{errors: errors}}}}
      )
      when is_list(errors) do
    failed = errors |> Enum.map(fn {target, _reason} -> to_string(target) end) |> MapSet.new()
    MapSet.intersection(targets, failed)
  end

  def failed_targets(%{reconcile_targets: _targets}, {:ok, _cache, _human_review_targets, _outcome}),
    do: MapSet.new()

  def failed_targets(%{reconcile_targets: targets}, _unrecognised), do: targets
  def failed_targets(_poll, _payload), do: MapSet.new()

  @spec schedule(Cursor.t(), Input.t(), non_neg_integer(), boolean(), keyword()) :: Cursor.t()
  def schedule(state, input, minimum_delay_ms \\ 0, replace_timer? \\ false, opts \\ [])

  def schedule(%Cursor{poll: poll} = state, _input, _minimum_delay_ms, _replace_timer?, _opts)
      when not is_nil(poll),
      do: state

  def schedule(%Cursor{} = state, %Input{} = input, minimum_delay_ms, replace_timer?, opts) do
    if Keyword.get(opts, :poll_frozen, false), do: state, else: do_schedule(state, input, minimum_delay_ms, replace_timer?)
  end

  defp do_schedule(%Cursor{reconcile_targets: targets} = state, input, minimum_delay_ms, replace_timer?) do
    if MapSet.size(targets) == 0 do
      cancel_reconcile_timer(state.reconcile_timer)
      %{state | reconcile_timer: nil}
    else
      delay_ms = max(minimum_delay_ms, input.next_github_delay_ms || 0)
      due_at_ms = System.monotonic_time(:millisecond) + delay_ms
      schedule_timer(state, delay_ms, due_at_ms, replace_timer?)
    end
  end

  defp schedule_timer(state, delay_ms, due_at_ms, true),
    do: replace_reconcile_timer(state, delay_ms, due_at_ms)

  defp schedule_timer(
         %Cursor{reconcile_timer: %{delay_ms: delay_ms}} = state,
         new_delay_ms,
         _due_at_ms,
         false
       )
       when delay_ms >= new_delay_ms,
       do: state

  defp schedule_timer(%Cursor{} = state, delay_ms, due_at_ms, false),
    do: replace_reconcile_timer(state, delay_ms, due_at_ms)

  defp replace_reconcile_timer(%Cursor{} = state, delay_ms, due_at_ms) do
    cancel_reconcile_timer(state.reconcile_timer)
    token = make_ref()
    message = {:run_github_comment_reconcile, token}

    timer_ref =
      if delay_ms == 0 do
        send(self(), message)
        nil
      else
        Process.send_after(self(), message, delay_ms)
      end

    %{
      state
      | reconcile_timer: %{
          token: token,
          timer_ref: timer_ref,
          delay_ms: delay_ms,
          due_at_ms: due_at_ms
        }
    }
  end

  defp cancel_reconcile_timer(%{timer_ref: timer_ref}) when is_reference(timer_ref), do: Process.cancel_timer(timer_ref)
  defp cancel_reconcile_timer(_timer), do: false
end
