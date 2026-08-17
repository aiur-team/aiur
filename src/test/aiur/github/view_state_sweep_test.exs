defmodule Aiur.GitHub.ViewStateSweepTest do
  @moduledoc """
  The sweep is the only view-state timer, and it exists for one reason: a webhook
  delivery that was lost. Every assertion here is a **count** — of timers, of
  reconcile calls, of recovered resources — never a latency.
  """

  use Aiur.TestSupport

  alias Aiur.GitHub.{ResourceStore, ViewStateSweep}

  # A view-state source is a module the sweep calls `refresh/0` on, registered
  # under its own name — so the stand-ins have to be real modules, not named
  # processes, or the test would not exercise the call the sweep actually makes.
  defmodule Source do
    @moduledoc false
    defmacro __using__(_opts) do
      quote do
        use GenServer

        def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
        def refresh, do: GenServer.cast(__MODULE__, :refresh)
        def calls, do: GenServer.call(__MODULE__, :calls)

        @impl true
        def init(_opts), do: {:ok, %{calls: 0}}

        @impl true
        def handle_call(:calls, _from, state), do: {:reply, state.calls, state}

        @impl true
        def handle_cast(:refresh, state), do: {:noreply, %{state | calls: state.calls + 1}}
      end
    end
  end

  defmodule SourceA do
    @moduledoc false
    use Source
  end

  defmodule SourceB do
    @moduledoc false
    use Source
  end

  defmodule SourceAbsent do
    @moduledoc false
    use Source
  end

  describe "the sweep is the only view-state cadence" do
    test "no view-state source schedules a GitHub read of its own" do
      # The three sources that used to hold 60s, 120s and 300s timers against
      # GitHub. This is a source-level assertion on purpose: a reviewer adding a
      # fourth cadence to one of them has to delete this test to do it.
      for source <- ViewStateSweep.sources() do
        body = File.read!(source_path(source))

        refute body =~ "Process.send_after(self(), :poll",
               "#{inspect(source)} still schedules its own GitHub cadence; ViewStateSweep is the only view-state timer"

        refute body =~ "@default_interval",
               "#{inspect(source)} still carries its own interval"
      end
    end

    test "the sources it sweeps are the three that hold GitHub view state" do
      assert ViewStateSweep.sources() == [
               Aiur.OpenTicketSource,
               Aiur.BuildOrder.AdHocSource,
               Aiur.BuildOrder.PackStatus
             ]
    end

    test "one tick reconciles every running source exactly once" do
      start_supervised!(SourceA)
      start_supervised!(SourceB)

      pid =
        start_supervised!({ViewStateSweep, name: :sweep_under_test, sources: [SourceA, SourceB], interval_ms: 3_600_000})

      assert ViewStateSweep.sweep_now(pid) == [SourceA, SourceB]

      assert SourceA.calls() == 1
      assert SourceB.calls() == 1
    end

    test "a source that is not running is skipped rather than started" do
      start_supervised!(SourceA)

      pid =
        start_supervised!({ViewStateSweep, name: :sweep_skip_test, sources: [SourceA, SourceAbsent], interval_ms: 3_600_000})

      assert ViewStateSweep.sweep_now(pid) == [SourceA]
      assert Process.whereis(SourceAbsent) == nil
    end

    test "it runs slowly, because it recovers losses rather than providing freshness" do
      pid = start_supervised!({ViewStateSweep, name: :sweep_interval_test, sources: []})

      # A recovery bound, not a refresh knob. Anything under a minute would mean
      # somebody had started treating it as the latter.
      assert ViewStateSweep.interval_ms(pid) >= :timer.minutes(1)
      assert ViewStateSweep.interval_ms(pid) == :timer.seconds(Aiur.Config.view_state_sweep_seconds())
    end

    test "its interval is operator-configurable, unlike the three cadences it replaced" do
      assert Aiur.Config.view_state_sweep_seconds() == 900
    end
  end

  describe "recovering a lost delivery" do
    setup do
      ResourceStore.reset()
      on_exit(fn -> ResourceStore.reset() end)
      :ok
    end

    # A6. Two comments exist upstream. One delivery arrived and was marked; the
    # other 502'd during a restart, GitHub retried it, and it never came. The
    # sweep reads both back and must publish exactly the one nothing handled.
    test "a resource whose delivery was dropped is published by the sweep, and its delivered sibling is not" do
      delivered = ResourceStore.key_for_repo(:issue_comment, "owner/repo", 5001)
      dropped = ResourceStore.key_for_repo(:issue_comment, "owner/repo", 5002)

      # The delivery that arrived. The one that did not leaves no trace at all —
      # that absence is exactly what makes it recoverable.
      ResourceStore.mark_processed(delivered, :webhook, "2026-08-17T10:00:00Z")

      upstream = [
        {delivered, "2026-08-17T10:00:00Z"},
        {dropped, "2026-08-17T09:00:00Z"}
      ]

      recovered =
        for {key, version} <- upstream, ResourceStore.claim(key, :poll, version) == :marked do
          key
        end

      assert recovered == [dropped]
    end

    # The hazard a timestamp watermark would have: the dropped comment is
    # *older* than the delivered one, so "ignore anything before the newest
    # thing I saw" loses it permanently. Identity plus version cannot.
    test "recovery does not depend on the dropped resource being the newest" do
      newest = ResourceStore.key_for_repo(:issue_comment, "owner/repo", 5004)
      older = ResourceStore.key_for_repo(:issue_comment, "owner/repo", 5003)

      ResourceStore.mark_processed(newest, :webhook, "2026-08-17T11:45:00Z")

      refute ResourceStore.processed?(older, "2026-08-17T11:30:00Z")
      assert ResourceStore.processed?(newest, "2026-08-17T11:45:00Z")
    end

    test "the sweep is never itself skipped, so there is no blind window" do
      # Every source is asked on every tick regardless of what the store holds:
      # suppression is decided per resource, never by skipping the pass.
      start_supervised!(SourceA)
      pid = start_supervised!({ViewStateSweep, name: :sweep_no_skip, sources: [SourceA], interval_ms: 3_600_000})

      for _tick <- 1..5, do: ViewStateSweep.sweep_now(pid)

      assert SourceA.calls() == 5
    end
  end

  describe "bounding suppression" do
    setup do
      ResourceStore.reset()
      on_exit(fn -> ResourceStore.reset() end)
      :ok
    end

    test "a versioned mark holds, because a change is what releases it" do
      key = ResourceStore.key_for_repo(:issue_comment, "owner/repo", 5010)
      ResourceStore.mark_processed(key, :webhook, "2026-08-17T10:00:00Z")

      age_mark!(key, :timer.hours(48))

      assert ResourceStore.processed?(key, "2026-08-17T10:00:00Z")
      refute ResourceStore.processed?(key, "2026-08-17T12:00:00Z")
    end

    # A mapping mistake — a writer that could not read a version — suppresses on
    # identity alone, and nothing the resource does will ever release it. It must
    # therefore not be able to hide the resource for the retention window.
    test "an identity-only mark expires on a much tighter bound" do
      key = ResourceStore.key_for_repo(:issue_comment, "owner/repo", 5011)
      ResourceStore.mark_processed(key, :webhook, nil)

      assert ResourceStore.processed?(key, nil)

      age_mark!(key, ResourceStore.unversioned_suppression_ms() + 1_000)

      refute ResourceStore.processed?(key, nil),
             "an unversioned mark suppressed past its bound; a mapping mistake can hide a resource"
    end

    test "the bound is far tighter than retention and far wider than a retry burst" do
      assert ResourceStore.unversioned_suppression_ms() >= :timer.minutes(5)
      assert ResourceStore.unversioned_suppression_ms() <= :timer.hours(2)
    end
  end

  # -- helpers --------------------------------------------------------------

  defp age_mark!(key, by_ms) do
    table = ResourceStore.Table
    [{^key, entry}] = :ets.lookup(table, key)
    :ets.insert(table, {key, Map.update!(entry, :processed_at_ms, &(&1 - by_ms))})
    :ok
  end

  defp source_path(module) do
    Path.join(["lib" | module |> Macro.underscore() |> Path.split()]) <> ".ex"
  end
end
