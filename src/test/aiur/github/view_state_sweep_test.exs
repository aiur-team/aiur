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

  # A stand-in for a real reconciliation source: on each sweep it reads its whole
  # upstream back and publishes only what nothing has claimed, which is exactly
  # the shape the comment sweep has.
  defmodule RecoveringSource do
    @moduledoc false
    use GenServer

    alias Aiur.GitHub.ResourceStore

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def refresh, do: GenServer.cast(__MODULE__, :refresh)
    def published, do: GenServer.call(__MODULE__, :published)

    @impl true
    def init(opts), do: {:ok, %{upstream: Keyword.fetch!(opts, :upstream), published: []}}

    @impl true
    def handle_call(:published, _from, state), do: {:reply, Enum.reverse(state.published), state}

    @impl true
    def handle_cast(:refresh, state) do
      published =
        Enum.reduce(state.upstream, state.published, fn {key, version}, acc ->
          if ResourceStore.claim(key, :poll, version) == :marked, do: [key | acc], else: acc
        end)

      {:noreply, %{state | published: published}}
    end
  end

  describe "the sweep is the only view-state cadence" do
    # The behavioural half: a source that still has a cadence has to keep the
    # interval somewhere, and every one of them kept it in `state.interval`.
    # Asserted against a live process rather than the source text.
    test "no view-state source holds an interval in its state" do
      for {source, opts} <- [
            {Aiur.OpenTicketSource, open_ticket_opts()},
            {Aiur.BuildOrder.AdHocSource, ad_hoc_opts()},
            {Aiur.BuildOrder.PackStatus, pack_status_opts()}
          ] do
        {:ok, pid} = source.start_link(Keyword.merge(opts, name: nil, poll_on_start: false))

        state = :sys.get_state(pid)

        refute Map.has_key?(state, :interval),
               "#{inspect(source)} still carries its own poll interval; ViewStateSweep is the only view-state cadence"

        # These are unlinked-from-the-suite children started by hand, so they are
        # stopped here rather than in `on_exit`, where the test process is gone
        # and a linked exit has already taken them down.
        Process.unlink(pid)
        Process.exit(pid, :kill)
      end
    end

    # The textual half, which catches the regression the state check cannot: a
    # cadence reintroduced under a different field name. A reviewer adding a
    # fourth cadence has to delete a test to do it.
    test "no view-state source schedules a GitHub read of its own" do
      for source <- ViewStateSweep.sources() do
        body = File.read!(source_path(source))

        refute body =~ "Process.send_after(self(), :poll",
               "#{inspect(source)} still schedules its own GitHub cadence; ViewStateSweep is the only view-state timer"

        refute body =~ "@default_interval",
               "#{inspect(source)} still carries its own interval"
      end
    end

    test "the source it sweeps is the one view-state writer left on a cadence" do
      # OpenTicketSource and AdHocSource were event-sourced (#2325) and hold no
      # timer; PackStatus writes `status.json` on disk and stays on the sweep
      # until its own event-stream PR lands. The acceptance for #2325 is that the
      # sweep "is deleted, or documents what it still sweeps and why".
      assert ViewStateSweep.sources() == [Aiur.BuildOrder.PackStatus]
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

    # Without this the module could sweep once at boot and never again — every
    # panel permanently stale — and every other test here would still pass,
    # because they all drive `sweep_now/1` by hand.
    test "the timer re-arms, so the sweep keeps running unattended" do
      start_supervised!(SourceA)
      start_supervised!({ViewStateSweep, name: :sweep_timer_test, sources: [SourceA], interval_ms: 20})

      assert eventually(fn -> SourceA.calls() >= 3 end),
             "the sweep did not tick repeatedly; it scheduled once and stopped"
    end

    # "One timer" is a property of the state, not of every caller remembering to
    # arm it once: arming cancels the previous reference, so a boot that both
    # sends an immediate sweep and arms a delayed one cannot leave two running
    # and silently double the sweep rate.
    test "however many paths arm it, exactly one timer is live" do
      start_supervised!(SourceA)

      pid =
        start_supervised!({ViewStateSweep, name: :sweep_on_start_test, sources: [SourceA], interval_ms: 3_600_000, sweep_on_start: true})

      assert eventually(fn -> SourceA.calls() >= 1 end)

      first = GenServer.call(pid, :timer)
      assert is_reference(first)
      assert Process.read_timer(first) > 0

      # The next tick re-arms, and the reference it replaced is dead rather than
      # still pending alongside the new one.
      send(pid, :sweep)
      assert eventually(fn -> GenServer.call(pid, :timer) != first end)
      assert Process.read_timer(first) == false
      assert Process.read_timer(GenServer.call(pid, :timer)) > 0
    end

    test "it runs slowly, because it recovers losses rather than providing freshness" do
      pid = start_supervised!({ViewStateSweep, name: :sweep_interval_test, sources: []})

      # A recovery bound, not a refresh knob. Anything under a minute would mean
      # somebody had started treating it as the latter.
      assert ViewStateSweep.interval_ms(pid) >= :timer.minutes(1)
      assert ViewStateSweep.interval_ms(pid) == :timer.seconds(Aiur.Config.view_state_sweep_seconds())
    end

    # Asserted against the schema rather than the resolved settings, so a
    # checkout whose own `.aiur/config` sets the key does not fail the suite.
    test "its interval is operator-configurable, unlike the three cadences it replaced" do
      assert %Aiur.Config.Schema.Polling{}.view_state_sweep_seconds == 900
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
    #
    # Driven through `ViewStateSweep` rather than by calling the store directly,
    # so deleting the sweep fails this test instead of leaving it green.
    test "a resource whose delivery was dropped is published by the sweep, and its delivered sibling is not" do
      delivered = ResourceStore.key_for_repo(:issue_comment, "owner/repo", 5001)
      dropped = ResourceStore.key_for_repo(:issue_comment, "owner/repo", 5002)

      # The delivery that arrived. The one that did not leaves no trace at all —
      # that absence is exactly what makes it recoverable.
      ResourceStore.mark_processed(delivered, :webhook, "2026-08-17T10:00:00Z")

      start_supervised!(
        {RecoveringSource,
         upstream: [
           {delivered, "2026-08-17T10:00:00Z"},
           {dropped, "2026-08-17T09:00:00Z"}
         ]}
      )

      pid =
        start_supervised!({ViewStateSweep, name: :sweep_a6, sources: [RecoveringSource], interval_ms: 3_600_000})

      assert ViewStateSweep.sweep_now(pid) == [RecoveringSource]
      assert eventually(fn -> RecoveringSource.published() == [dropped] end)

      # And a second sweep recovers nothing further: the first one marked it, so
      # the recovery does not become a repeating wake.
      ViewStateSweep.sweep_now(pid)
      Process.sleep(50)
      assert RecoveringSource.published() == [dropped]
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

    # `claim/3` consults the shared predicate inside its own compare-and-swap
    # rather than going through `processed?/2`, so a bound applied only on the
    # read path would leave the atomic claim suppressing an unversioned mark for
    # the full retention window. The sweep claims, so this is the path that
    # actually decides whether a mapping mistake hides a resource.
    test "the atomic claim honours the bound, not just the read" do
      key = ResourceStore.key_for_repo(:issue_comment, "owner/repo", 5012)

      assert :marked = ResourceStore.claim(key, :webhook, nil)
      assert :already_processed = ResourceStore.claim(key, :poll, nil)

      age_mark!(key, ResourceStore.unversioned_suppression_ms() + 1_000)

      assert :marked = ResourceStore.claim(key, :poll, nil),
             "a sweep could not recover a resource whose unversioned mark had passed its bound"
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

  # Stubs only so each source can boot without a token or a network; the test
  # asserts on state shape and never lets a fetch run.
  defp open_ticket_opts do
    [request_fun: &stub_request/1, repo_fun: fn -> {:ok, {"owner", "repo"}} end, token_fun: fn -> {:ok, "t"} end]
  end

  defp ad_hoc_opts, do: open_ticket_opts()

  defp pack_status_opts do
    [request_fun: &stub_request/1, token_fun: fn -> {:ok, "t"} end, paths_fun: fn -> [] end]
  end

  defp stub_request(_request), do: {:ok, %{status: 200, body: [], headers: []}}

  defp source_path(module) do
    root = Application.app_dir(:aiur) |> Path.join("../../../..") |> Path.expand()
    Path.join([root, "lib" | module |> Macro.underscore() |> Path.split()]) <> ".ex"
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end
end
