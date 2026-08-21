defmodule Aiur.GitHub.CacheHistoryTest do
  @moduledoc """
  The bounded time-series sampler behind the `/github-cache` history charts.

  The important properties: a sample is a measurement of the store as it stood
  at one moment (never a fabricated zero when the store is absent), the ring is
  bounded, and the sampler can be driven deterministically for the page's live
  redraw without depending on wall-clock cadence.
  """

  use Aiur.TestSupport

  alias Aiur.GitHub.CacheHistory
  alias Aiur.GithubCacheSourceSupport, as: Source

  @now ~U[2026-08-18 12:00:00Z]

  defmodule UnavailableSource do
    @behaviour Aiur.GitHub.CacheInspector.Source
    @impl true
    def available?, do: false
    @impl true
    def entries, do: []
  end

  # A fresh entry per index, so totals track the fixture size directly.
  defp entry(index) do
    %{
      key: {:issue_comment, "owner", "repo", Integer.to_string(index)},
      etag: "etag-#{index}",
      source: :webhook,
      fetched_at_ms: DateTime.to_unix(DateTime.utc_now(), :millisecond),
      data?: true,
      data: %{"id" => index}
    }
  end

  defp start_history(opts) do
    # `name: nil` keeps the sampler unregistered, so tests never contend with
    # the app-started singleton on the `CacheHistory` name; `start_supervised!`
    # returns the pid the calls below are made against.
    start_supervised!({CacheHistory, Keyword.merge([name: nil], opts)})
  end

  describe "samples/1 and sample/1" do
    test "records a boot fill and appends forced samples oldest-first" do
      Source.install([entry(1)])
      pid = start_history(interval_ms: 0, clock: fn -> @now end)

      assert [first] = CacheHistory.samples(pid)
      assert first.total == 1
      assert first.t_ms == DateTime.to_unix(@now, :millisecond)

      Source.install([entry(1), entry(2)])
      :ok = CacheHistory.sample(pid)

      assert [one, two] = CacheHistory.samples(pid)
      assert one.total == 1
      assert two.total == 2
    end

    test "a bounded ring drops the oldest samples" do
      Source.install([entry(1)])
      pid = start_history(interval_ms: 0, capacity: 2)

      for count <- 2..4 do
        Source.install(Enum.map(1..count, &entry/1))
        :ok = CacheHistory.sample(pid)
      end

      samples = CacheHistory.samples(pid)
      assert length(samples) == 2
      # The boot fill (1) and the first forced sample (2) were pushed out.
      assert Enum.map(samples, & &1.total) == [3, 4]
    end

    test "an unavailable store records nothing rather than a zero" do
      Application.put_env(:aiur, :github_cache_inspector_source, UnavailableSource)
      on_exit(fn -> Application.delete_env(:aiur, :github_cache_inspector_source) end)

      pid = start_history(interval_ms: 0)
      assert CacheHistory.samples(pid) == []

      :ok = CacheHistory.sample(pid)
      assert CacheHistory.samples(pid) == []
    end

    test "answers [] when no sampler is running" do
      # A CLI invocation or a page test that never started one: the page must
      # render its collecting state, not crash on a missing process.
      assert CacheHistory.samples(:no_such_cache_history) == []
    end
  end

  describe "cadence" do
    test "auto-samples on its interval" do
      Source.install([entry(1)])
      pid = start_history(interval_ms: 20)

      assert eventually(fn -> length(CacheHistory.samples(pid)) >= 3 end)
    end

    test "interval 0 disables auto-sampling" do
      Source.install([entry(1)])
      pid = start_history(interval_ms: 0)

      Process.sleep(60)
      # Only the boot fill: nothing sampled itself without a cadence.
      assert length(CacheHistory.samples(pid)) == 1
    end
  end

  describe "subscribe/0" do
    test "broadcasts a notification after each sample" do
      Source.install([entry(1)])
      pid = start_history(interval_ms: 0)

      CacheHistory.subscribe()
      :ok = CacheHistory.sample(pid)

      assert_receive {:cache_history_sampled, _count}
    end
  end

  defp eventually(fun, attempts \\ 60)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, _attempts), do: false
end
