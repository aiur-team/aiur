defmodule Aiur.Commands.OverrideRouteTest do
  use ExUnit.Case, async: true

  alias Aiur.Commands.OverrideRoute

  test "every PR, worker and capacity combination has exactly the required route" do
    capacities = [:available, :full, :unknown]
    workers = [:active, :resumable, :unrecoverable, :unknown]

    for pr <- [:merged, %{merged?: true}], worker <- workers, capacity <- capacities do
      assert OverrideRoute.choose(pr, worker, capacity) == :corrective_ticket
    end

    for pr <- [:open, :closed, :unknown, nil, %{merged?: false}] do
      for capacity <- capacities do
        assert OverrideRoute.choose(pr, :active, capacity) == :active_worker
        assert OverrideRoute.choose(pr, :unrecoverable, capacity) == :replacement
      end

      for worker <- [:resumable, :unknown] do
        assert OverrideRoute.choose(pr, worker, :full) == :capacity_wait
        assert OverrideRoute.choose(pr, worker, :available) == :resume_pending
        assert OverrideRoute.choose(pr, worker, :unknown) == :resume_pending
      end
    end
  end

  test "unrecognized observations remain queued instead of dispatching" do
    assert OverrideRoute.choose(:future_state, :future_state, :future_state) == :resume_pending
  end
end
