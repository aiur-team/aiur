defmodule Aiur.ModelDiscovery.CliCatalogueTest do
  use ExUnit.Case, async: true

  alias Aiur.CodingAgent
  alias Aiur.ModelDiscovery

  setup context do
    dir = Aiur.TestSupport.tmp_root!("aiur-model-discovery-#{:erlang.phash2(context.test)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, cache: Path.join(dir, "model-catalog.json")}
  end

  describe "CLI catalogues (codex, claude answer `model/list`)" do
    test "codex and claude are discoverable through their CLI, and claude-repl shares claude's entry" do
      assert ModelDiscovery.discoverable?("codex")
      assert ModelDiscovery.discoverable?("claude")
      assert ModelDiscovery.source_key("claude-repl") == "claude"
      assert ModelDiscovery.source_key("codex") == "codex"
    end

    test "a refresh stores the ids the CLI lists, so a model newer than this build is known", %{cache: cache} do
      assert {:ok, _result} = ModelDiscovery.refresh("codex", path: cache, discover: cli(["gpt-5.7-astra", "gpt-5.6-sol"]))

      assert {ids, :discovered} = ModelDiscovery.catalogue("codex", path: cache)
      assert "gpt-5.7-astra" in ids
      refute "gpt-5.7-astra" in CodingAgent.seedable_models("codex")
    end

    test "claude-repl reads the catalogue a claude refresh wrote", %{cache: cache} do
      assert {:ok, _result} = ModelDiscovery.refresh("claude", path: cache, discover: cli(["opus", "opus-5-5"]))

      assert {ids, :discovered} = ModelDiscovery.catalogue("claude-repl", path: cache)
      assert "opus-5-5" in ids
    end

    test "a backend never discovered reads as curated-only; one opted out reads as discovered", %{cache: cache} do
      assert {curated, :curated_only} = ModelDiscovery.catalogue("codex", path: cache)
      assert curated == CodingAgent.seedable_models("codex")
      assert {_ids, :discovered} = ModelDiscovery.catalogue("codex", path: cache, enabled: false)
    end

    test "a failed refresh keeps the last good ids and records the attempt", %{cache: cache} do
      assert {:ok, _result} =
               ModelDiscovery.refresh("codex", path: cache, discover: cli(["gpt-5.7-astra"]), now: ~U[2026-09-01 00:00:00Z])

      assert {:error, :model_list_timeout} =
               ModelDiscovery.refresh("codex", path: cache, discover: fn _ -> {:error, :model_list_timeout} end, now: ~U[2026-09-02 00:00:00Z])

      assert {ids, :discovered} = ModelDiscovery.catalogue("codex", path: cache)
      assert "gpt-5.7-astra" in ids
      assert get_in(ModelDiscovery.load(cache), ["backends", "codex", "last_attempt_at"]) == "2026-09-02T00:00:00Z"
      assert get_in(ModelDiscovery.load(cache), ["backends", "codex", "fetched_at"]) == "2026-09-01T00:00:00Z"
    end

    test "refresh_now probes at most once per cooldown window, after a failure and after a success", %{cache: cache} do
      counter = :counters.new(1, [])
      failing = fn _ -> :counters.add(counter, 1, 1) && {:error, :cli_unavailable} end
      t0 = ~U[2026-09-01 00:00:00Z]

      assert {:error, :cli_unavailable} = ModelDiscovery.refresh_now("codex", path: cache, discover: failing, now: t0)
      assert {:ok, :cooldown} = ModelDiscovery.refresh_now("codex", path: cache, discover: failing, now: DateTime.add(t0, 599))
      assert :counters.get(counter, 1) == 1

      ok = fn _ -> :counters.add(counter, 1, 1) && {:ok, ["gpt-5.7-astra"]} end
      assert {:ok, _result} = ModelDiscovery.refresh_now("codex", path: cache, discover: ok, now: DateTime.add(t0, 600))
      assert {:ok, :cooldown} = ModelDiscovery.refresh_now("codex", path: cache, discover: ok, now: DateTime.add(t0, 700))
      assert :counters.get(counter, 1) == 2
    end

    test "a stale entry tried within the cooldown is not due for a background refresh", %{cache: cache} do
      t0 = ~U[2026-09-01 00:00:00Z]
      ModelDiscovery.refresh("codex", path: cache, discover: fn _ -> {:error, :cli_unavailable} end, now: t0)

      assert ModelDiscovery.stale?("codex", path: cache, now: DateTime.add(t0, 60))
      refute ModelDiscovery.refresh_due?("codex", path: cache, now: DateTime.add(t0, 60))
      assert ModelDiscovery.refresh_due?("codex", path: cache, now: DateTime.add(t0, 600))
    end

    test "refresh_now is a no-op when the operator switched discovery off", %{cache: cache} do
      assert {:ok, :disabled} = ModelDiscovery.refresh_now("codex", path: cache, enabled: false, discover: &never_discover/1)
    end

    test "a CLI probe that crashes is a failed attempt, not a crash in the caller", %{cache: cache} do
      crashing = fn _ -> raise "port died" end

      assert {:error, {:discover_crashed, "port died"}} = ModelDiscovery.refresh_now("codex", path: cache, discover: crashing)
      assert get_in(ModelDiscovery.load(cache), ["backends", "codex", "last_attempt_at"])
      assert {:ok, :cooldown} = ModelDiscovery.refresh_now("codex", path: cache, discover: crashing)
    end

    test "a probe that outlives the budget times out and still cools the backend down", %{cache: cache} do
      slow = fn _ -> Process.sleep(:infinity) end

      assert {:error, :refresh_timeout} = ModelDiscovery.refresh_now("codex", path: cache, discover: slow, timeout_ms: 20)
      assert {:ok, :cooldown} = ModelDiscovery.refresh_now("codex", path: cache, discover: slow, timeout_ms: 20)
    end

    test "refresh_now honours the application kill switch unless a source is injected", %{cache: cache} do
      # `:model_discovery_refresh?` is false under `:test`.
      assert {:ok, :disabled} = ModelDiscovery.refresh_now("codex", path: cache)
    end

    test "runners refreshing the same catalogue at once probe it once", %{cache: cache} do
      counter = :counters.new(1, [])

      discover = fn _ ->
        :counters.add(counter, 1, 1)
        Process.sleep(50)
        {:ok, ["gpt-5.7-astra"]}
      end

      ["codex", "codex", "codex"]
      |> Enum.map(fn backend -> Task.async(fn -> ModelDiscovery.refresh_now(backend, path: cache, discover: discover) end) end)
      |> Task.await_many()

      assert :counters.get(counter, 1) == 1
    end

    test "the background refresh respects the cooldown too", %{cache: cache} do
      t0 = ~U[2026-09-01 00:00:00Z]
      ModelDiscovery.refresh("codex", path: cache, discover: fn _ -> {:error, :cli_unavailable} end, now: t0)

      refute ModelDiscovery.background_refresh_due?("codex", path: cache, now: DateTime.add(t0, 60))
      assert ModelDiscovery.background_refresh_due?("codex", path: cache, now: DateTime.add(t0, 600))
    end

    test "a CLI probe that exits is a failed attempt too", %{cache: cache} do
      assert {:error, {:discover_crashed, {:exit, :port_closed}}} =
               ModelDiscovery.refresh_now("codex", path: cache, discover: fn _ -> exit(:port_closed) end)

      assert {:ok, :cooldown} = ModelDiscovery.refresh_now("codex", path: cache, discover: fn _ -> exit(:port_closed) end)
    end

    test "refreshes of different catalogues written at once all land", %{cache: cache} do
      for _round <- 1..15 do
        File.rm(cache)
        slowish = fn source -> Process.sleep(5) && {:ok, ["#{source}-model"]} end

        [Task.async(fn -> ModelDiscovery.refresh("codex", path: cache, discover: slowish) end), Task.async(fn -> ModelDiscovery.refresh("claude", path: cache, discover: slowish) end)]
        |> Task.await_many()

        backends = ModelDiscovery.load(cache)["backends"]
        assert Map.keys(backends) |> Enum.sort() == ["claude", "codex"]
      end
    end

    test "the memoized read sees every rewrite, even one of the same size in the same second", %{cache: cache} do
      # Same-length ids: the file size and (usually) the mtime do not change
      # between the two writes, so only the rewrite's new inode reveals it.
      t = ~U[2026-09-01 00:00:00Z]
      ModelDiscovery.refresh("codex", path: cache, discover: cli(["gpt-5.7-aaaaa"]), now: t)
      assert {ids, _} = ModelDiscovery.catalogue("codex", memo_path: cache)
      assert "gpt-5.7-aaaaa" in ids

      ModelDiscovery.refresh("codex", path: cache, discover: cli(["gpt-5.7-bbbbb"]), now: t)
      assert {ids, _} = ModelDiscovery.catalogue("codex", memo_path: cache)
      assert "gpt-5.7-bbbbb" in ids
      refute "gpt-5.7-aaaaa" in ids
    end

    test "an HTTP catalogue never fetched does not read as curated-only", %{cache: cache} do
      assert {_ids, :discovered} = ModelDiscovery.catalogue("openrouter", path: cache)
    end

    test "catalogue reads never start a refresh", %{cache: cache} do
      assert {_ids, :curated_only} = ModelDiscovery.catalogue("codex", path: cache, discover: &never_discover/1)
    end
  end

  defp cli(ids), do: fn _backend -> {:ok, ids} end

  defp never_discover(_backend), do: flunk("a CLI probe ran where none was allowed")
end
