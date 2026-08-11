defmodule Aiur.DecisionStore.RetainedIndexTest do
  @moduledoc """
  The awaiting counts are what the banner, the nav badge and every filter chip
  render, and they are derived by subtraction from two counters the index
  maintains incrementally (`open - deferred`, `blocking - deferred_blocking`).
  Counters kept in step by hand drift silently, and the way that drift reaches
  an operator is a banner claiming a number the list underneath it contradicts —
  the exact defect this surface was rebuilt to fix.

  So these tests do not restate the arithmetic. They assert the invariant the
  arithmetic exists to hold: the awaiting counts always equal what a caller
  listing the same lifecycle sets would actually see.
  """

  use ExUnit.Case, async: true

  alias Aiur.Decision
  alias Aiur.DecisionStore.RetainedIndex

  describe "canonical_counts/1" do
    test "awaiting tracks the listed open set through open -> deferred -> decided" do
      blocking = decision("dec-blocking", true)
      quiet = decision("dec-quiet", false)
      other = decision("dec-other", true)

      blocking_ids = MapSet.new([blocking.decision_id, other.decision_id])

      index =
        RetainedIndex.build(%{
          blocking.decision_id => blocking,
          quiet.decision_id => quiet,
          other.decision_id => other
        })

      assert_invariant(index, blocking_ids)
      counts = RetainedIndex.canonical_counts(index)
      assert counts.open == 3
      assert counts.deferred == 0
      assert counts.awaiting == 3
      assert counts.awaiting_blocking == 2

      # Deferring hands the Command to the Executor. The unit is still blocked,
      # so `open`/`blocking` must not move — but the operator no longer owns it,
      # so `awaiting` must.
      deferred = %{blocking | decision_status: :deferred}
      index = RetainedIndex.update(index, blocking, deferred)

      assert_invariant(index, blocking_ids)
      counts = RetainedIndex.canonical_counts(index)
      assert counts.open == 3
      assert counts.blocking == 2
      assert counts.deferred == 1
      assert counts.awaiting == 2
      assert counts.awaiting_blocking == 1

      # Answering leaves the open set entirely.
      decided = %{deferred | decision_status: :decided}
      index = RetainedIndex.update(index, deferred, decided)

      assert_invariant(index, blocking_ids)
      counts = RetainedIndex.canonical_counts(index)
      assert counts.open == 2
      assert counts.blocking == 1
      assert counts.deferred == 0
      assert counts.awaiting == 2
      assert counts.awaiting_blocking == 1
      assert counts.total == 3
    end

    test "holds the invariant across a full status walk, blocking and not" do
      walk = [:deferred, :decided, :open, :acknowledged, :deferred, :resolved, :expired, :open, :dismissed, :open]

      for blocking? <- [true, false] do
        subject = decision("dec-walk-#{blocking?}", blocking?)
        companion = decision("dec-companion-#{blocking?}", not blocking?)

        blocking_ids =
          [subject, companion]
          |> Enum.filter(& &1.blocking)
          |> MapSet.new(& &1.decision_id)

        index =
          RetainedIndex.build(%{subject.decision_id => subject, companion.decision_id => companion})

        Enum.reduce(walk, {index, subject}, fn status, {index, prior} ->
          next = %{prior | decision_status: status}
          index = RetainedIndex.update(index, prior, next)

          assert_invariant(index, blocking_ids)

          {index, next}
        end)
      end
    end

    test "a Command that leaves the index takes its awaiting count with it" do
      open = decision("dec-alert", true)
      index = RetainedIndex.build(%{open.decision_id => open})

      assert RetainedIndex.canonical_counts(index).awaiting == 1

      # A delivery-failure attention is an operational alert, not an operator
      # Command. Updating into one drops the entry, and the awaiting count has
      # to drop with it rather than stranding a unit the inbox will never list.
      alert = %{open | legacy_attention: %{slug: "decision-delivery-failed"}}
      index = RetainedIndex.update(index, open, alert)

      assert_invariant(index, MapSet.new([open.decision_id]))
      counts = RetainedIndex.canonical_counts(index)
      assert counts.open == 0
      assert counts.awaiting == 0
      assert counts.awaiting_blocking == 0
      assert counts.total == 0
    end
  end

  # The counts are only worth rendering if they agree with what a caller listing
  # the same lifecycles would see, so that is exactly what is compared.
  defp assert_invariant(index, blocking_ids) do
    counts = RetainedIndex.canonical_counts(index)
    open_ids = ids(index, :open)
    deferred_ids = ids(index, :deferred)

    assert counts.awaiting == length(open_ids)
    assert counts.deferred == length(deferred_ids)
    assert counts.open == length(open_ids) + length(deferred_ids)
    assert counts.awaiting_blocking == count_blocking(open_ids, blocking_ids)
    assert counts.blocking == count_blocking(open_ids ++ deferred_ids, blocking_ids)
    assert counts.awaiting >= 0
    assert counts.awaiting_blocking >= 0
  end

  defp ids(index, status) do
    index
    |> RetainedIndex.lifecycle(status, :audit)
    |> :gb_sets.to_list()
    |> Enum.map(fn {_created_at, decision_id} -> decision_id end)
  end

  defp count_blocking(decision_ids, blocking_ids), do: Enum.count(decision_ids, &MapSet.member?(blocking_ids, &1))

  defp decision(decision_id, blocking?) do
    %Decision{
      decision_id: decision_id,
      version: 1,
      ticket: %{identifier: "EX-1", title: "Example", url: nil},
      source: %{agent_id: "agent-1", session_id: "session-1", event_id: nil},
      authority: :human_required,
      urgency: :normal,
      blocking: blocking?,
      reversibility: :reversible,
      question: "Ship the example?",
      context: %{},
      options: [],
      artifacts: [],
      created_at: DateTime.utc_now(),
      content_hash: "hash-#{decision_id}"
    }
  end
end
