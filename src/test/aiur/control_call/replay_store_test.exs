defmodule Aiur.ControlCall.ReplayStoreTest do
  use ExUnit.Case, async: false

  alias Aiur.ControlCall.ReplayStore

  setup do
    dir = Path.join(System.tmp_dir!(), "replay-store-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :control_replay_state_dir)
    previous_limits = Application.get_env(:aiur, :control_replay)
    Application.put_env(:aiur, :control_replay_state_dir, dir)
    clock = start_supervised!({Agent, fn -> 1_000 end})
    set_limits(now_fun: fn _ -> Agent.get(clock, & &1) end)
    {:ok, store} = GenServer.start_link(ReplayStore, [])

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :control_replay_state_dir, previous), else: Application.delete_env(:aiur, :control_replay_state_dir)
      if previous_limits, do: Application.put_env(:aiur, :control_replay, previous_limits), else: Application.delete_env(:aiur, :control_replay)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{store: store, dir: dir, clock: clock}
  end

  test "claim, finish and replay the stored response", %{store: s} do
    assert :new = ReplayStore.claim("t", "a", "h1", s)
    assert :in_progress = ReplayStore.claim("t", "a", "h1", s)
    assert :reused = ReplayStore.claim("t", "a", "h2", s)
    assert :ok = ReplayStore.finish("t", "a", 200, %{output: "x"}, "ok", s)
    assert {:replay, 200, %{"output" => "x"}, "ok"} = ReplayStore.claim("t", "a", "h1", s)
    assert :new = ReplayStore.claim("other", "a", "h1", s)
  end

  test "a restart keeps completed entries and turns a begin without end into outcome_unknown", %{store: s} do
    :new = ReplayStore.claim("t", "done", "h", s)
    :ok = ReplayStore.finish("t", "done", 200, %{output: "x"}, "ok", s)
    :new = ReplayStore.claim("t", "mid", "h", s)
    :ok = ReplayStore.reload(s)

    assert {:replay, 200, %{"output" => "x"}, "ok"} = ReplayStore.claim("t", "done", "h", s)
    assert {:replay, 409, %{"error" => %{"code" => "outcome_unknown"}}, "outcome_unknown"} = ReplayStore.claim("t", "mid", "h", s)
  end

  test "a torn final begin line leaves that id unseen", %{store: s, dir: dir} do
    :new = ReplayStore.claim("t", "a", "h", s)
    File.write!(Path.join(dir, "replay.ndjson"), ~s({"t":"begin","token":"t","id":"torn","ha), [:append])
    :ok = ReplayStore.reload(s)

    assert :new = ReplayStore.claim("t", "torn", "h", s)
  end

  test "entries expire after the ttl and the id runs as new", %{store: s, clock: clock} do
    :new = ReplayStore.claim("t", "a", "h", s)
    :ok = ReplayStore.finish("t", "a", 200, %{}, "ok", s)
    Agent.update(clock, &(&1 + 86_400_001))
    :ok = ReplayStore.compact(s)

    assert :new = ReplayStore.claim("t", "a", "h", s)
  end

  test "the oldest completed entry is evicted at the cap and in-flight entries never are", %{store: s, clock: clock} do
    set_limits(now_fun: fn _ -> Agent.get(clock, & &1) end, max_entries: 2)

    for id <- ["1", "2"] do
      Agent.update(clock, &(&1 + 1))
      :new = ReplayStore.claim("t", id, "h", s)
      :ok = ReplayStore.finish("t", id, 200, %{}, "ok", s)
    end

    assert :new = ReplayStore.claim("t", "3", "h", s)
    assert {:replay, 200, _, "ok"} = ReplayStore.claim("t", "2", "h", s)
    assert :new = ReplayStore.claim("t", "1", "h", s)
    # "1" and "3" are in flight and "2" was evicted to make room; nothing completed is left to evict.
    assert {:error, :full} = ReplayStore.claim("t", "4", "h", s)
  end

  test "an oversized response is stored as result_not_retained", %{store: s} do
    set_limits(max_body_bytes: 100)
    :new = ReplayStore.claim("t", "a", "h", s)
    :ok = ReplayStore.finish("t", "a", 200, %{output: String.duplicate("x", 500)}, "ok", s)

    assert {:replay, 409, %{"error" => %{"code" => "result_not_retained"}}, "result_too_large"} = ReplayStore.claim("t", "a", "h", s)
  end

  test "an over-cap file is rotated to .bad and the store starts empty", %{store: s, dir: dir} do
    :new = ReplayStore.claim("t", "a", "h", s)
    set_limits(max_file_bytes: 10)
    :ok = ReplayStore.reload(s)

    assert :new = ReplayStore.claim("t", "a", "h", s)
    assert [_bad] = Path.wildcard(Path.join(dir, "replay.ndjson.*.bad"))
  end

  test "an unwritable state dir makes claims unavailable", %{store: s} do
    Application.put_env(:aiur, :control_replay_state_dir, "/proc/not/writable")
    :ok = ReplayStore.reload(s)

    assert {:error, :unavailable} = ReplayStore.claim("t", "a", "h", s)
  end

  defp set_limits(opts) do
    base = Application.get_env(:aiur, :control_replay, [])
    Application.put_env(:aiur, :control_replay, Keyword.merge(base, opts))
  end
end
