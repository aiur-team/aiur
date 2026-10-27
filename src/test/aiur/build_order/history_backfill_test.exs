defmodule Aiur.BuildOrder.HistoryBackfillTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias Aiur.BuildOrder.HistoryBackfill, as: Backfill

  setup do
    dir = Aiur.TestSupport.tmp_root!("history-agent-backfill")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    opts = [state_dir: dir, repository: "acme/app", cap: 5, catalog: fn -> {:ok, [%{key: "bugs"}]} end, features: fn -> {:ok, %{features: %{}}} end, export: &export/1]
    %{dir: dir, path: Path.join(dir, "2901.json"), opts: opts}
  end

  defp export(opts) do
    rows = for n <- 1..20, n > opts[:after], do: %{number: n, title: "row #{n}", unknown: []}
    {:ok, page(Enum.take(rows, opts[:limit]))}
  end

  defp page(rows, freshness \\ :current, unresolved \\ 0),
    do: %{
      tickets: rows,
      next_after: nil,
      matching_total: 20,
      unresolved_total: unresolved,
      sources: %{history: %{state: :available, freshness: freshness, age_ms: 41000, observed_at: DateTime.utc_now()}}
    }

  test "page is persisted before return and cap/cursor survive a new call", c do
    assert {:ok, first} = Backfill.next_page(2901, 3, 0, c.opts)
    assert first.handed_out == 3 and first.remaining == 2 and first.cursor == 3
    assert Enum.map(first.rows, & &1.number) == [1, 2, 3]
    assert first.rows == elem(export(after: 0, limit: 3), 1).tickets
    saved = Jason.decode!(File.read!(c.path))
    assert saved["handed_out"] == 3 and saved["cursor"] == 3
    assert saved["cap"] == 5 and saved["issue"] == 2901 and saved["repository"] == "acme/app"
    assert (File.stat!(c.path).mode &&& 0o777) == 0o600
    assert {:ok, second} = Backfill.next_page(2901, 50, 999, Keyword.put(c.opts, :cap, 100))
    assert Enum.map(second.rows, & &1.number) == [4, 5]
    assert second.cap == 5 and second.cap_reached and second.handed_out == 5
    bytes = File.read!(c.path)
    assert {:ok, %{rows: [], cap_reached: true, handed_out: 5}} = Backfill.next_page(2901, 1, 0, c.opts)
    assert File.read!(c.path) == bytes
  end

  test "parallel calls spend each allocation only once", c do
    opts =
      Keyword.put(c.opts, :export, fn request ->
        Process.sleep(20)
        export(request)
      end)

    results = 1..10 |> Task.async_stream(fn _ -> Backfill.next_page(2901, 1, 0, opts) end, max_concurrency: 10, timeout: 30_000) |> Enum.map(fn {:ok, {:ok, p}} -> p end)
    rows = Enum.flat_map(results, & &1.rows)
    assert Enum.sort(Enum.map(rows, & &1.number)) == [1, 2, 3, 4, 5]
    assert Jason.decode!(File.read!(c.path))["handed_out"] == 5
  end

  test "checkpoint write failure returns no rows and spends nothing", c do
    opts = Keyword.put(c.opts, :writer, fn _, _, _ -> {:error, :enospc} end)
    assert {:error, :history_backfill_checkpoint_failed} = Backfill.next_page(2901, 2, 0, opts)
    refute File.exists?(c.path)
    assert {:ok, %{handed_out: 2, cursor: 2}} = Backfill.next_page(2901, 2, 0, c.opts)
  end

  test "bad checkpoint is unavailable and never reset", c do
    File.mkdir_p!(c.dir)
    File.write!(c.path, "{bad")
    opts = Keyword.put(c.opts, :catalog, fn -> flunk("checkpoint must be read first") end)
    assert {:error, :history_backfill_checkpoint_unavailable} = Backfill.next_page(2901, 1, 0, opts)
    assert File.read!(c.path) == "{bad"
  end

  test "wrong identity, invalid counters and symlinks do not grant another cap", c do
    assert {:ok, _} = Backfill.next_page(2901, 1, 0, c.opts)
    saved = Jason.decode!(File.read!(c.path))

    for changes <- [
          %{"version" => 2},
          %{"repository" => "other/repo"},
          %{"issue" => 12},
          %{"cap" => 0},
          %{"handed_out" => 6},
          %{"handed_out" => -1},
          %{"cursor" => -1},
          %{"updated_at" => "bad"},
          %{"extra" => true}
        ] do
      bytes = Jason.encode!(Map.merge(saved, changes))
      File.write!(c.path, bytes)
      assert {:error, :history_backfill_checkpoint_unavailable} = Backfill.next_page(2901, 1, 0, c.opts)
      assert File.read!(c.path) == bytes
    end

    File.rename!(c.path, c.path <> ".target")
    File.ln_s!(c.path <> ".target", c.path)
    assert {:error, :history_backfill_checkpoint_unavailable} = Backfill.next_page(2901, 1, 0, c.opts)
    assert {:ok, %{type: :symlink}} = File.lstat(c.path)
  end

  test "a first start_after skips forward and cannot later rewind", c do
    assert {:ok, %{rows: [%{number: 11}], cursor: 11}} = Backfill.next_page(2901, 1, 10, c.opts)
    assert {:ok, %{rows: [%{number: 12}], cursor: 12}} = Backfill.next_page(2901, 1, 0, c.opts)
  end

  test "only current empty resolved history is exhausted", c do
    for {freshness, unresolved, expected} <- [{:current, 0, true}, {"current", 3, false}, {:stale, 0, nil}, {"unknown", 0, nil}] do
      opts = Keyword.put(c.opts, :export, fn _ -> {:ok, page([], freshness, unresolved)} end)
      assert {:ok, result} = Backfill.next_page(2901, 1, 0, opts)
      assert result.exhausted == expected
      assert result.history.age_ms == 41000 and result.history.freshness == freshness
      assert result.unresolved_total == unresolved
    end
  end

  test "unavailable catalog, features and History spend nothing", c do
    for {key, reader, reason} <- [
          {:catalog, fn -> {:error, :epic_config_unavailable} end, :epic_catalog_unavailable},
          {:features, fn -> {:error, :unavailable} end, :feature_registry_unavailable},
          {:export, fn _ -> {:error, "history backfill incomplete"} end, {:history_unavailable, "history backfill incomplete"}}
        ] do
      opts = Keyword.put(c.opts, key, reader)
      opts = if key == :export, do: opts, else: Keyword.put(opts, :export, fn _ -> flunk("export called") end)
      assert {:error, ^reason} = Backfill.next_page(2901, 1, 0, opts)
      refute File.exists?(c.path)
    end
  end

  test "production default uses the measured 100-ticket cap", c do
    opts = c.opts |> Keyword.delete(:cap) |> Keyword.put(:export, fn opts -> {:ok, page(for n <- 1..opts[:limit], do: %{number: opts[:after] + n})} end)
    assert {:ok, %{cap: 100, handed_out: 50, cap_reached: false}} = Backfill.next_page(2901, 50, 0, opts)
    assert {:ok, %{handed_out: 100, cap_reached: true}} = Backfill.next_page(2901, 50, 0, opts)
    assert {:ok, %{rows: [], handed_out: 100}} = Backfill.next_page(2901, 50, 0, opts)
  end
end
